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

    // Load local model preference (default: OFF)
    m_localModelEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kLocalModelEnabledKey];

    // Wire up recorder callbacks
    m_recorder->onRecordingFinished = [this](const std::string& filePath) {
        NSLog(@"Recording finished: %s", filePath.c_str());
        setState(State::Transcribing);
        m_lastWavPath = filePath;

        if (m_groqTranscriber->isReady()) {
            m_groqTranscriber->transcribe(filePath);
        } else if (m_localModelEnabled && m_transcriber->isReady()) {
            m_transcriber->transcribe(filePath);
        } else {
            NSLog(@"No transcription backend available");
            setState(State::Ready);
        }
    };

    m_recorder->onRecordingError = [this](const std::string& error) {
        NSLog(@"Recording error: %s", error.c_str());
        setState(State::Ready);
    };

    // Wire up Groq transcriber callbacks
    m_groqTranscriber->onTranscriptionComplete = [this](const std::string& text) {
        NSLog(@"Groq transcription complete: %s", text.c_str());
        if (!text.empty()) {
            TextInjector::typeText(text);
        }
        if (m_state != State::Recording) {
            setState(State::Ready);
        }
    };

    m_groqTranscriber->onTranscriptionError = [this](const std::string& error) {
        NSLog(@"Groq transcription error: %s", error.c_str());

        // Check if this is a retryable error (rate limit or network)
        bool retryable = error.find("[groq_rate_limit]") != std::string::npos ||
                         error.find("[groq_network_error]") != std::string::npos;

        if (retryable && !m_lastWavPath.empty()) {
            fallbackToLocal(m_lastWavPath);
        } else {
            if (m_state != State::Recording) {
                setState(State::Ready);
            }
        }
    };

    // Wire up local whisper transcriber callbacks
    m_transcriber->onTranscriptionComplete = [this](const std::string& text) {
        NSLog(@"Local transcription complete: %s", text.c_str());
        if (!text.empty()) {
            TextInjector::typeText(text);
        }
        if (m_state != State::Recording) {
            setState(State::Ready);
        }
    };

    m_transcriber->onTranscriptionError = [this](const std::string& error) {
        NSLog(@"Local transcription error: %s", error.c_str());
        if (m_state != State::Recording) {
            setState(State::Ready);
        }
    };

    m_transcriber->onReady = [this]() {
        NSLog(@"Whisper model ready");
        // If Groq is not configured, this makes us ready
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

    // Initialize local model only if enabled
    if (m_localModelEnabled) {
        m_transcriber->initialize();
    }

    // If Groq API key is set, we're ready immediately
    if (m_groqTranscriber->isReady()) {
        setState(State::Ready);
    } else if (!m_localModelEnabled) {
        // No Groq key and no local model — stay initializing so status shows guidance
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

void AppController::fallbackToLocal(const std::string& wavFilePath)
{
    if (m_localModelEnabled && m_transcriber->isReady()) {
        NSLog(@"Falling back to local whisper model");
        m_transcriber->transcribe(wavFilePath);
    } else {
        NSLog(@"Local model not available for fallback");
        if (m_state != State::Recording) {
            setState(State::Ready);
        }
    }
}

void AppController::toggleRecording()
{
    switch (m_state) {
    case State::Initializing:
        NSLog(@"Still initializing, ignoring toggle");
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
