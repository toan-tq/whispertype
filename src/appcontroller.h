#pragma once
#include <functional>
#include <queue>
#include <string>

class VoiceRecorder;
class WhisperTranscriber;
class GroqTranscriber;

class AppController {
public:
    enum class State { Initializing, Ready, Recording, Transcribing };

    AppController();
    ~AppController();

    void toggleRecording();
    State state() const { return m_state; }
    bool isDownloading() const;
    double downloadProgress() const;

    void setLocalModelEnabled(bool enabled);
    bool isLocalModelEnabled() const;

    std::function<void(State)> onStateChanged;
    std::function<void(double)> onDownloadProgress;
    std::function<void()> onDownloadStarted;
    std::function<void(const std::string&)> onHotkeyIgnored;

private:
    void setState(State state);
    void enqueueTranscription(const std::string& wavFilePath);
    void processNext();
    void finishTranscription();
    void deleteWavFile(const std::string& wavFilePath);

    VoiceRecorder *m_recorder;
    WhisperTranscriber *m_transcriber;
    GroqTranscriber *m_groqTranscriber;
    State m_state = State::Initializing;
    bool m_localModelEnabled = false;
    std::queue<std::string> m_transcriptionQueue;
    bool m_transcribing = false;
};
