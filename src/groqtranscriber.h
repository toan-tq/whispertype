#pragma once
#include <functional>
#include <string>

class GroqTranscriber {
public:
    GroqTranscriber();
    ~GroqTranscriber();

    void transcribe(const std::string& wavFilePath);
    bool isReady() const;

    std::function<void(const std::string&)> onTranscriptionComplete;
    std::function<void(const std::string&)> onTranscriptionError;

private:
    std::string m_apiKey;
    void *m_session = nullptr;  // NSURLSession*
};
