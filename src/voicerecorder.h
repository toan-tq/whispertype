#pragma once
#include <functional>
#include <string>

class VoiceRecorder {
public:
    VoiceRecorder();
    ~VoiceRecorder();

    void startRecording();
    void stopRecording();
    bool isRecording() const { return m_isRecording; }

    // Directory holding in-flight recordings. Audio that could not be transcribed
    // is kept in "failed/" underneath it so nothing said is lost silently.
    static std::string cacheDirectory();

    std::function<void(const std::string&)> onRecordingFinished;
    std::function<void(const std::string&)> onRecordingError;

private:
    void *m_impl = nullptr;
    bool m_isRecording = false;
};
