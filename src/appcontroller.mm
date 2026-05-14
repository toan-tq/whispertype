#include "appcontroller.h"
#include "voicerecorder.h"
#include "whispertranscriber.h"
#include "groqtranscriber.h"
#include "textinjector.h"
#import <Foundation/Foundation.h>

static NSString *const kLocalModelEnabledKey = @"LocalModelEnabled";

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

    // Each transcribe() call carries its own wavPath via the callback, so the
    // shared handler is safe across queued/concurrent requests. We still
    // serialize requests at this layer to preserve typing order.
    m_groqTranscriber->onTranscriptionComplete = [this](const std::string& wavPath, const std::string& text) {
        NSLog(@"Groq transcription complete: %s", text.c_str());
        if (!text.empty()) TextInjector::typeText(text);
        deleteWavFile(wavPath);
        finishTranscription();
    };

    m_groqTranscriber->onTranscriptionError = [this](const std::string& wavPath, const std::string& error) {
        NSLog(@"Groq transcription error: %s", error.c_str());

        bool retryable = error.find("[groq_rate_limit]") != std::string::npos ||
                         error.find("[groq_network_error]") != std::string::npos;

        if (retryable && m_localModelEnabled && m_transcriber->isReady()) {
            NSLog(@"Falling back to local whisper model");
            m_transcriber->transcribe(wavPath);
            return;
        }

        deleteWavFile(wavPath);
        finishTranscription();
    };

    m_transcriber->onTranscriptionComplete = [this](const std::string& wavPath, const std::string& text) {
        NSLog(@"Local transcription complete: %s", text.c_str());
        if (!text.empty()) TextInjector::typeText(text);
        deleteWavFile(wavPath);
        finishTranscription();
    };

    m_transcriber->onTranscriptionError = [this](const std::string& wavPath, const std::string& error) {
        NSLog(@"Local transcription error: %s", error.c_str());
        deleteWavFile(wavPath);
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

void AppController::enqueueTranscription(const std::string& wavFilePath)
{
    m_transcriptionQueue.push(wavFilePath);
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
            deleteWavFile(path);
            continue;
        }

        m_transcribing = true;
        if (!m_recorder->isRecording()) setState(State::Transcribing);

        if (hasGroq) {
            m_groqTranscriber->transcribe(path);
        } else {
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

void AppController::deleteWavFile(const std::string& wavFilePath)
{
    if (wavFilePath.empty()) return;
    NSString *path = [NSString stringWithUTF8String:wavFilePath.c_str()];
    if (!path) return;
    NSError *err = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&err]) {
        NSLog(@"Failed to delete WAV file %@: %@", path, err);
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
