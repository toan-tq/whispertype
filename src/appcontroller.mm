#include "appcontroller.h"
#include "voicerecorder.h"
#include "whispertranscriber.h"
#include "groqtranscriber.h"
#include "textinjector.h"
#import <Foundation/Foundation.h>

static NSString *const kLocalModelEnabledKey = @"LocalModelEnabled";
static NSString *const kPreferLocalKey = @"PreferLocalModel";
// Keep each transcribed recording and its text under <cache>/samples/ as a test set for
// comparing models (tools/bench_local.py). Off by default.
static NSString *const kKeepRecordingsKey = @"KeepRecordings";

static double monotonicNow() { return [NSProcessInfo processInfo].systemUptime; }

// "[groq_network_error] Timed out after 45s" -> "Timed out after 45s", capped for the menu.
static std::string shortReason(const std::string& error)
{
    std::string s = error;
    if (!s.empty() && s[0] == '[') {
        size_t end = s.find("] ");
        if (end != std::string::npos) s = s.substr(end + 2);
    }
    size_t nl = s.find_first_of("\r\n");
    if (nl != std::string::npos) s = s.substr(0, nl);
    if (s.size() > 80) s = s.substr(0, 77) + "...";
    return s;
}

AppController::AppController()
{
    m_recorder = new VoiceRecorder();
    m_transcriber = new WhisperTranscriber();
    m_groqTranscriber = new GroqTranscriber();

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    m_localModelEnabled = [defaults boolForKey:kLocalModelEnabledKey];
    m_preferLocal = m_localModelEnabled && [defaults boolForKey:kPreferLocalKey];

    m_recorder->onRecordingFinished = [this](const std::string& filePath) {
        enqueueTranscription(filePath);
    };

    // Covers both a microphone that would not start and a recording that broke off.
    m_recorder->onRecordingError = [this](const std::string& error) {
        NSLog(@"Recording error: %s", error.c_str());
        m_stopPressedAt = 0;
        if (m_state == State::Recording) setState(m_transcribing ? State::Transcribing : State::Ready);
        if (onHotkeyIgnored) onHotkeyIgnored("Microphone: " + shortReason(error));
    };

    // Each transcribe() call carries its own path via the callback, so the shared
    // handler is safe across queued/concurrent requests. We still serialize requests
    // at this layer to preserve typing order.
    m_groqTranscriber->onStatus = [this](const std::string& /*path*/, const std::string& status) {
        if (onStatusMessage) onStatusMessage(status, false);
    };

    m_groqTranscriber->onTranscriptionComplete = [this](const std::string& path, const std::string& text) {
        transcriptionSucceeded(path, text);
    };

    m_groqTranscriber->onTranscriptionError = [this](const std::string& path, const std::string& error) {
        NSLog(@"Groq transcription error: %s", error.c_str());

        bool retryable = error.find("[groq_rate_limit]") != std::string::npos ||
                         error.find("[groq_network_error]") != std::string::npos ||
                         error.find("[groq_server_error]") != std::string::npos;

        if (retryable && !m_triedLocal && m_localModelEnabled && m_transcriber->isReady()) {
            NSLog(@"Falling back to local whisper model");
            if (onStatusMessage) onStatusMessage("Transcribing locally (Groq failed)", false);
            startEngine(Engine::Local, path);
            return;
        }
        transcriptionFailed(path, error);
    };

    m_transcriber->onTranscriptionComplete = [this](const std::string& path, const std::string& text) {
        transcriptionSucceeded(path, text);
    };

    m_transcriber->onTranscriptionError = [this](const std::string& path, const std::string& error) {
        NSLog(@"Local transcription error: %s", error.c_str());
        // Local was tried first (PreferLocalModel): Groq is the fallback.
        if (!m_triedGroq && m_groqTranscriber->isReady()) {
            NSLog(@"Falling back to Groq");
            if (onStatusMessage) onStatusMessage("Sending to Groq (local failed)", false);
            startEngine(Engine::Groq, path);
            return;
        }
        transcriptionFailed(path, error);
    };

    m_transcriber->onReady = [this]() {
        NSLog(@"Whisper model ready");
        if (m_state == State::Initializing) setState(State::Ready);
    };

    m_transcriber->onLoadFailed = [this](const std::string& error) {
        NSLog(@"Local model unavailable: %s", error.c_str());
        if (onLocalModelError) onLocalModelError(shortReason(error));
    };

    m_transcriber->onDownloadProgress = [this](double progress) {
        if (onDownloadProgress) onDownloadProgress(progress);
    };

    m_transcriber->onDownloadStarted = [this]() {
        if (onDownloadStarted) onDownloadStarted();
    };

    if (m_localModelEnabled) {
        m_transcriber->initialize();
    }

    if (m_groqTranscriber->isReady()) {
        setState(State::Ready);
    } else if (!m_localModelEnabled) {
        NSLog(@"No Groq API key set and local model disabled");
    }
}

AppController::~AppController()
{
    delete m_recorder;
    delete m_transcriber;
    delete m_groqTranscriber;
}

bool AppController::isDownloading() const
{
    return m_transcriber->isDownloading();
}

double AppController::downloadProgress() const
{
    return m_transcriber->downloadProgress();
}

void AppController::setLocalModelEnabled(bool enabled)
{
    m_localModelEnabled = enabled;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kLocalModelEnabledKey];

    if (enabled) {
        m_transcriber->initialize();
    } else {
        // Give the memory back: large-v3-turbo holds ~2 GB while loaded.
        m_transcriber->release();
        if (m_preferLocal) {
            m_preferLocal = false;
            [defaults setBool:NO forKey:kPreferLocalKey];
        }
    }
}

bool AppController::isLocalModelEnabled() const
{
    return m_localModelEnabled;
}

void AppController::setPreferLocal(bool prefer)
{
    m_preferLocal = prefer;
    [[NSUserDefaults standardUserDefaults] setBool:prefer forKey:kPreferLocalKey];
    if (prefer && !m_localModelEnabled) setLocalModelEnabled(true);
}

bool AppController::isPreferLocal() const
{
    return m_preferLocal;
}

void AppController::setState(State state)
{
    if (m_state != state) {
        m_state = state;
        NSLog(@"AppController state: %d", static_cast<int>(state));
        if (onStateChanged) onStateChanged(state);
    }
}

void AppController::enqueueTranscription(const std::string& audioFilePath)
{
    PendingAudio item;
    item.path = audioFilePath;
    item.readyAt = monotonicNow();
    item.stopAt = m_stopPressedAt > 0 ? m_stopPressedAt : item.readyAt;  // auto-stop: no key press
    m_stopPressedAt = 0;

    m_transcriptionQueue.push(item);
    if (m_transcribing) {
        // Recording just ended while another transcription is still running;
        // surface Transcribing state if the mic is no longer active.
        NSLog(@"Queued behind the transcription in progress (%zu waiting)", m_transcriptionQueue.size());
        if (!m_recorder->isRecording()) setState(State::Transcribing);
    } else {
        processNext();
    }
}

void AppController::processNext()
{
    while (!m_transcribing && !m_transcriptionQueue.empty()) {
        PendingAudio item = m_transcriptionQueue.front();
        m_transcriptionQueue.pop();

        bool hasGroq = m_groqTranscriber->isReady();
        bool hasLocal = m_localModelEnabled && m_transcriber->isReady();

        if (!hasGroq && !hasLocal) {
            NSLog(@"No transcription backend available");
            keepFailedAudio(item.path);
            if (onTranscriptionFailed) onTranscriptionFailed("No transcription backend available");
            continue;
        }

        m_transcribing = true;
        m_current = item;
        m_triedGroq = false;
        m_triedLocal = false;
        m_currentStartedAt = monotonicNow();
        if (!m_recorder->isRecording()) setState(State::Transcribing);

        Engine engine = (hasLocal && (m_preferLocal || !hasGroq)) ? Engine::Local : Engine::Groq;
        if (onStatusMessage) {
            onStatusMessage(engine == Engine::Groq ? "Sending to Groq" : "Transcribing locally", true);
        }
        startEngine(engine, item.path);
        return;
    }

    if (!m_transcribing && !m_recorder->isRecording()) {
        setState(State::Ready);
    }
}

// By value: a synchronous failure inside transcribe() can finish this item and start the
// next one, which overwrites m_current while we are still on the stack.
void AppController::startEngine(Engine engine, std::string path)
{
    m_currentEngine = engine;
    if (engine == Engine::Groq) {
        m_triedGroq = true;
        m_groqTranscriber->transcribe(path);
    } else {
        m_triedLocal = true;
        m_transcriber->transcribe(path);
    }
}

void AppController::transcriptionSucceeded(const std::string& pathRef, const std::string& textRef)
{
    std::string path = pathRef;
    std::string text = textRef;
    double doneAt = monotonicNow();
    if (!text.empty()) TextInjector::typeText(text);
    double typedAt = monotonicNow();

    // The one line to read when it "feels slow": which stage the seconds went to.
    //   stop->file: recorder finalising the file   queued: waiting behind an earlier recording
    //   groq/local: transcription (Groq timing line above breaks it down further)
    NSLog(@"Timing: stop->file %.0f ms, queued %.0f ms, %s %.2f s%s, typing %.0f ms => stop->text %.2f s",
          (m_current.readyAt - m_current.stopAt) * 1000.0,
          (m_currentStartedAt - m_current.readyAt) * 1000.0,
          m_currentEngine == Engine::Local ? "local" : "groq",
          doneAt - m_currentStartedAt,
          (m_triedGroq && m_triedLocal) ? " (after fallback)" : "",
          (typedAt - doneAt) * 1000.0,
          typedAt - m_current.stopAt);
    NSLog(@"Transcript (%s): %s", m_currentEngine == Engine::Local ? "local" : "groq", text.c_str());

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kKeepRecordingsKey]) {
        keepSample(path, text);
    } else {
        removeAudio(path);
    }
    if (onTranscriptionSucceeded) onTranscriptionSucceeded();
    finishTranscription();
}

void AppController::transcriptionFailed(const std::string& pathRef, const std::string& errorRef)
{
    std::string path = pathRef;
    std::string error = errorRef;
    keepFailedAudio(path);
    if (onTranscriptionFailed) onTranscriptionFailed(shortReason(error));
    finishTranscription();
}

void AppController::finishTranscription()
{
    m_transcribing = false;
    m_currentEngine = Engine::None;
    if (!m_transcriptionQueue.empty()) {
        processNext();
    } else if (!m_recorder->isRecording()) {
        setState(State::Ready);
    }
}

void AppController::removeAudio(const std::string& audioFilePath)
{
    if (audioFilePath.empty()) return;
    NSString *path = [NSString stringWithUTF8String:audioFilePath.c_str()];
    if (!path) return;
    NSError *err = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&err]) {
        NSLog(@"Failed to delete audio file %@: %@", path, err);
    }
}

// Move a recording that could not be transcribed into <cache>/failed/ so the user can
// recover what was said. VoiceRecorder purges that folder after a week.
void AppController::keepFailedAudio(const std::string& audioFilePath)
{
    if (audioFilePath.empty()) return;
    NSString *path = [NSString stringWithUTF8String:audioFilePath.c_str()];
    if (!path) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[NSString stringWithUTF8String:VoiceRecorder::cacheDirectory().c_str()]
                     stringByAppendingPathComponent:@"failed"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *dest = [dir stringByAppendingPathComponent:[path lastPathComponent]];
    NSError *err = nil;
    if ([fm moveItemAtPath:path toPath:dest error:&err]) {
        NSLog(@"Kept failed audio at %@", dest);
    } else {
        NSLog(@"Failed to keep audio %@: %@", path, err);
        [fm removeItemAtPath:path error:nil];
    }
}

// KeepRecordings: <cache>/samples/voice_<time>.wav plus voice_<time>.txt holding what was
// typed. Correct the .txt files by hand to turn them into a reference test set. Not purged.
void AppController::keepSample(const std::string& audioFilePath, const std::string& text)
{
    NSString *path = [NSString stringWithUTF8String:audioFilePath.c_str()];
    if (!path) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[NSString stringWithUTF8String:VoiceRecorder::cacheDirectory().c_str()]
                     stringByAppendingPathComponent:@"samples"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *dest = [dir stringByAppendingPathComponent:[path lastPathComponent]];
    NSError *err = nil;
    if (![fm moveItemAtPath:path toPath:dest error:&err]) {
        NSLog(@"Failed to keep sample %@: %@", path, err);
        [fm removeItemAtPath:path error:nil];
        return;
    }
    NSString *txt = [[dest stringByDeletingPathExtension] stringByAppendingPathExtension:@"txt"];
    NSString *content = [NSString stringWithUTF8String:text.c_str()] ?: @"";
    [[content stringByAppendingString:@"\n"] writeToFile:txt atomically:YES
                                                encoding:NSUTF8StringEncoding error:nil];
}

void AppController::toggleRecording()
{
    switch (m_state) {
    case State::Initializing:
        NSLog(@"Still initializing, ignoring toggle");
        if (onHotkeyIgnored) {
            if (m_groqTranscriber->isReady()) {
                onHotkeyIgnored("Initializing...");
            } else if (m_transcriber->isDownloading()) {
                onHotkeyIgnored("Downloading model...");
            } else if (m_localModelEnabled) {
                onHotkeyIgnored("Local model not ready");
            } else {
                onHotkeyIgnored("Set Groq API key first");
            }
        }
        break;
    case State::Ready:
    case State::Transcribing:
        NSLog(@"Starting recording%s...", m_state == State::Transcribing ? " while transcribing" : "");
        // A microphone that does not start must not leave the app in Recording: the next
        // key press would then try to stop a recording that does not exist, and nothing
        // but a restart would get the app out of that state.
        if (!m_recorder->startRecording()) break;  // reported through onRecordingError
        setState(State::Recording);
        if (!(m_preferLocal && m_transcriber->isReady())) m_groqTranscriber->prewarm();
        break;
    case State::Recording:
        NSLog(@"Stopping recording...");
        m_stopPressedAt = monotonicNow();
        m_recorder->stopRecording();
        break;
    }
}
