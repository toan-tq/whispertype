#pragma once
#include <functional>
#include <string>

class GroqTranscriber {
public:
    GroqTranscriber();
    ~GroqTranscriber();

    void transcribe(const std::string& audioFilePath);
    bool isReady() const;

    std::function<void(const std::string& path, const std::string& text)> onTranscriptionComplete;
    // Error strings carry a tag prefix the controller keys on:
    //   [groq_network_error]  transport failure or timeout   (retried once, then fallback-eligible)
    //   [groq_server_error]   HTTP 5xx                        (retried once, then fallback-eligible)
    //   [groq_rate_limit]     HTTP 429                        (retried once, then fallback-eligible)
    //   [groq_api_error]      anything else                   (not retried)
    std::function<void(const std::string& path, const std::string& error)> onTranscriptionError;
    // Human-readable progress for the menu: "Uploading 43%", "Waiting for Groq", "Retrying".
    std::function<void(const std::string& path, const std::string& status)> onStatus;

private:
    void startRequest(const std::string& path, int attempt);
    void completeRequest(const std::string& path, int attempt, double elapsed,
                         long errorCode, const std::string& errorText,
                         long httpStatus, const std::string& responseBody);
    void handleFailure(const std::string& path, int attempt, const std::string& error, bool retryable);

    std::string m_apiKey;
    void *m_session = nullptr;   // NSURLSession*
    void *m_delegate = nullptr;  // GroqSessionDelegate*
};
