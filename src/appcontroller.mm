#include "appcontroller.h"
#include "voicerecorder.h"
#include "whispertranscriber.h"
#include "groqtranscriber.h"
#include "textinjector.h"
#import <Foundation/Foundation.h>

static NSString *const kLocalModelEnabledKey = @"LocalModelEnabled";

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

    m_localModelEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kLocalModelEnabledKey];

    m_recorder->onRecordingFinished = [this](const std::string& filePath) {
        NSLog(@"Recording finished: %s", filePath.c_str());
        enqueueTranscription(filePath);
    };

    m_recorder->onRecordingError = [this](const std::string& error) {
        NSLog(@"Recording error: %s", error.c_str());
        if (m_state == State::Recording) setState(State::Ready);
    };

    // Each transcribe() call carries its own path via the callback, so the shared
    // handler is safe across queued/concurrent requests. We still serialize requests
    // at this layer to preserve typing order.
    m_groqTranscriber->onStatus = [this](const std::string& /*path*/, const std::string& status) {
        if (onStatusMessage) onStatusMessage(status, false);
    };

    m_groqTranscriber->onTranscriptionComplete = [this](const std::string& path, const std::string& text) {
        NSLog(@"Groq transcription complete: %s", text.c_str());
        if (!text.empty()) TextInjector::typeText(text);
        removeAudio(path);
        if (onTranscriptionSucceeded) onTranscriptionSucceeded();
        finishTranscription();
    };

    m_groqTranscriber->onTranscriptionError = [this](const std::string& path, const std::string& error) {
        NSLog(@"Groq transcription error: %s", error.c_str());

        bool retryable = error.find("[groq_rate_limit]") != std::string::npos ||
                         error.find("[groq_network_error]") != std::string::npos ||
                         error.find("[groq_server_error]") != std::string::npos;

        if (retryable && m_localModelEnabled && m_transcriber->isReady()) {
            NSLog(@"Falling back to local whisper model");
            if (onStatusMessage) onStatusMessage("Transcribing locally (Groq failed)", false);
            m_transcriber->transcribe(path);
            return;
        }

        keepFailedAudio(path);
        if (onTranscriptionFailed) onTranscriptionFailed(shortReason(error));
        finishTranscription();
    };

    m_transcriber->onTranscriptionComplete = [this](const std::string& path, const std::string& text) {
        NSLog(@"Local transcription complete: %s", text.c_str());
        if (!text.empty()) TextInjector::typeText(text);
        removeAudio(path);
        if (onTranscriptionSucceeded) onTranscriptionSucceeded();
        finishTranscription();
    };

    m_transcriber->onTranscriptionError = [this](const std::string& path, const std::string& error) {
        NSLog(@"Local transcription error: %s", error.c_str());
        keepFailedAudio(path);
        if (onTranscriptionFailed) onTranscriptionFailed(shortReason(error));
        finishTranscription();
    };

    m_transcriber->onReady = [this]() {
        NSLog(@"Whisper model ready");
        if (!m_groqTranscriber->isReady()) {
            setState(State::Ready);
        }
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
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kLocalModelEnabledKey];

    if (enabled) {
        m_transcriber->initialize();
    }
}

bool AppController::isLocalModelEnabled() const
{
    return m_localModelEnabled;
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
    m_transcriptionQueue.push(audioFilePath);
    if (m_transcribing) {
        // Recording just ended while another transcription is still running;
        // surface Transcribing state if the mic is no longer active.
        if (!m_recorder->isRecording()) setState(State::Transcribing);
    } else {
        processNext();
    }
}

void AppController::processNext()
{
    while (!m_transcribing && !m_transcriptionQueue.empty()) {
        std::string path = m_transcriptionQueue.front();
        m_transcriptionQueue.pop();

        bool hasGroq = m_groqTranscriber->isReady();
        bool hasLocal = m_localModelEnabled && m_transcriber->isReady();

        if (!hasGroq && !hasLocal) {
            NSLog(@"No transcription backend available");
            keepFailedAudio(path);
            if (onTranscriptionFailed) onTranscriptionFailed("No transcription backend available");
            continue;
        }

        m_transcribing = true;
        if (!m_recorder->isRecording()) setState(State::Transcribing);

        if (hasGroq) {
            if (onStatusMessage) onStatusMessage("Sending to Groq", true);
            m_groqTranscriber->transcribe(path);
        } else {
            if (onStatusMessage) onStatusMessage("Transcribing locally", true);
            m_transcriber->transcribe(path);
        }
        return;
    }

    if (!m_transcribing && !m_recorder->isRecording()) {
        setState(State::Ready);
    }
}

void AppController::finishTranscription()
{
    m_transcribing = false;
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
            } else {
                onHotkeyIgnored("Set Groq API key first");
            }
        }
        break;
    case State::Ready:
        NSLog(@"Starting recording...");
        m_recorder->startRecording();
        setState(State::Recording);
        break;
    case State::Recording:
        NSLog(@"Stopping recording...");
        m_recorder->stopRecording();
        break;
    case State::Transcribing:
        NSLog(@"Starting recording while transcribing...");
        m_recorder->startRecording();
        setState(State::Recording);
        break;
    }
}
