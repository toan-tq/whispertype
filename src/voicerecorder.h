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

    std::function<void(const std::string&)> onRecordingFinished;
    std::function<void(const std::string&)> onRecordingError;

private:
    void *m_impl = nullptr;
    bool m_isRecording = false;
};
