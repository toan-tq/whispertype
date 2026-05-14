#pragma once
#include <functional>
#include <string>

class GroqTranscriber {
public:
    GroqTranscriber();
    ~GroqTranscriber();

    void transcribe(const std::string& wavFilePath);
    bool isReady() const;

    std::function<void(const std::string& wavPath, const std::string& text)> onTranscriptionComplete;
    std::function<void(const std::string& wavPath, const std::string& error)> onTranscriptionError;

private:
    std::string m_apiKey;
    void *m_session = nullptr;  // NSURLSession*
};
