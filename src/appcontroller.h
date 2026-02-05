#pragma once
#include <functional>

class VoiceRecorder;
class WhisperTranscriber;

class AppController {
public:
    enum class State { Initializing, Ready, Recording, Transcribing };

    AppController();
    ~AppController();

    void toggleRecording();
    State state() const { return m_state; }
    bool isDownloading() const;
    double downloadProgress() const;

    std::function<void(State)> onStateChanged;
    std::function<void(double)> onDownloadProgress;
    std::function<void()> onDownloadStarted;

private:
    void setState(State state);

    VoiceRecorder *m_recorder;
    WhisperTranscriber *m_transcriber;
    State m_state = State::Initializing;
};
