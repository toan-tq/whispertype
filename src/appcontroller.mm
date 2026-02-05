#include "appcontroller.h"
#include "voicerecorder.h"
#include "whispertranscriber.h"
#include "textinjector.h"
#import <Foundation/Foundation.h>

AppController::AppController()
{
    m_recorder = new VoiceRecorder();
    m_transcriber = new WhisperTranscriber();

    // Wire up recorder callbacks
    m_recorder->onRecordingFinished = [this](const std::string& filePath) {
        NSLog(@"Recording finished: %s", filePath.c_str());
        setState(State::Transcribing);
        m_transcriber->transcribe(filePath);
    };

    m_recorder->onRecordingError = [this](const std::string& error) {
        NSLog(@"Recording error: %s", error.c_str());
        setState(State::Ready);
    };

    // Wire up transcriber callbacks
    m_transcriber->onTranscriptionComplete = [this](const std::string& text) {
        NSLog(@"Transcription complete: %s", text.c_str());
        if (!text.empty()) {
            TextInjector::typeText(text);
        }
        if (m_state != State::Recording) {
            setState(State::Ready);
        }
    };

    m_transcriber->onTranscriptionError = [this](const std::string& error) {
        NSLog(@"Transcription error: %s", error.c_str());
        if (m_state != State::Recording) {
            setState(State::Ready);
        }
    };

    m_transcriber->onReady = [this]() {
        NSLog(@"Whisper model ready");
        setState(State::Ready);
    };

    m_transcriber->onDownloadProgress = [this](double progress) {
        if (onDownloadProgress) onDownloadProgress(progress);
    };

    m_transcriber->onDownloadStarted = [this]() {
        if (onDownloadStarted) onDownloadStarted();
    };

    m_transcriber->initialize();
}

AppController::~AppController()
{
    delete m_recorder;
    delete m_transcriber;
}

bool AppController::isDownloading() const
{
    return m_transcriber->isDownloading();
}

double AppController::downloadProgress() const
{
    return m_transcriber->downloadProgress();
}

void AppController::setState(State state)
{
    if (m_state != state) {
        m_state = state;
        NSLog(@"AppController state: %d", static_cast<int>(state));
        if (onStateChanged) onStateChanged(state);
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
