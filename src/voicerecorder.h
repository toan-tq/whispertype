#pragma once
#include <functional>
#include <string>

class VoiceRecorder {
public:
    VoiceRecorder();
    ~VoiceRecorder();

    // Returns false when the microphone could not be started (onRecordingError has
    // already been called). The caller must then not consider the app to be recording.
    bool startRecording();
    void stopRecording();
    bool isRecording() const { return m_isRecording; }

    // Directory holding in-flight recordings. Audio that could not be transcribed
    // is kept in "failed/" underneath it so nothing said is lost silently.
    static std::string cacheDirectory();

    std::function<void(const std::string&)> onRecordingFinished;
    std::function<void(const std::string&)> onRecordingError;

private:
    // Single exit for a recording (delegate callback, encode error or watchdog).
    // Main thread only; later calls for the same recording are ignored.
    void finish(bool ok, const std::string& error);

    void *m_impl = nullptr;
    bool m_isRecording = false;
    double m_stopRequestedAt = 0;
};
