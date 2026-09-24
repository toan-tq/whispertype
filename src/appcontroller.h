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
    // Progress of the transcription in flight ("Uploading 43%", "Waiting for Groq").
    // newItem is true when a new recording starts being processed, so the UI can
    // restart its elapsed-time clock.
    std::function<void(const std::string& text, bool newItem)> onStatusMessage;
    // A recording could not be transcribed; its audio was kept in the "failed" folder.
    std::function<void(const std::string& reason)> onTranscriptionFailed;
    std::function<void()> onTranscriptionSucceeded;

private:
    void setState(State state);
    void enqueueTranscription(const std::string& audioFilePath);
    void processNext();
    void finishTranscription();
    void removeAudio(const std::string& audioFilePath);
    void keepFailedAudio(const std::string& audioFilePath);

    VoiceRecorder *m_recorder;
    WhisperTranscriber *m_transcriber;
    GroqTranscriber *m_groqTranscriber;
    State m_state = State::Initializing;
    bool m_localModelEnabled = false;
    std::queue<std::string> m_transcriptionQueue;
    bool m_transcribing = false;
};
