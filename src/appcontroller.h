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
    // Transcribe on this Mac first and use Groq only as the fallback (no upload wait).
    // Turning it on also turns the local model on.
    void setPreferLocal(bool prefer);
    bool isPreferLocal() const;

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
    // The local model could not be downloaded or loaded.
    std::function<void(const std::string& reason)> onLocalModelError;

private:
    enum class Engine { None, Groq, Local };

    struct PendingAudio {
        std::string path;
        double stopAt = 0;   // when the user pressed stop (or the file was ready, for auto-stop)
        double readyAt = 0;  // when the recorder handed the file over
    };

    void setState(State state);
    void enqueueTranscription(const std::string& audioFilePath);
    void processNext();
    void startEngine(Engine engine, std::string path);
    void transcriptionSucceeded(const std::string& path, const std::string& text);
    void transcriptionFailed(const std::string& path, const std::string& error);
    void finishTranscription();
    void removeAudio(const std::string& audioFilePath);
    void keepFailedAudio(const std::string& audioFilePath);
    void keepSample(const std::string& audioFilePath, const std::string& text);

    VoiceRecorder *m_recorder;
    WhisperTranscriber *m_transcriber;
    GroqTranscriber *m_groqTranscriber;
    State m_state = State::Initializing;
    bool m_localModelEnabled = false;
    bool m_preferLocal = false;
    std::queue<PendingAudio> m_transcriptionQueue;
    bool m_transcribing = false;

    // The recording being transcribed, for fallback decisions and the timing log.
    PendingAudio m_current;
    Engine m_currentEngine = Engine::None;
    bool m_triedGroq = false;
    bool m_triedLocal = false;
    double m_currentStartedAt = 0;
    double m_stopPressedAt = 0;
};
