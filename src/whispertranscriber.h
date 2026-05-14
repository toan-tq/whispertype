#pragma once
#include <functional>
#include <string>
#include <atomic>
#include <mutex>

struct whisper_context;

class WhisperTranscriber {
public:
    WhisperTranscriber();
    ~WhisperTranscriber();

    void initialize();
    void transcribe(const std::string& wavFilePath);
    bool isReady() const { return m_isReady.load(); }
    bool isDownloading() const { return m_isDownloading; }
    double downloadProgress() const { return m_downloadProgress; }

    std::function<void(const std::string& wavPath, const std::string& text)> onTranscriptionComplete;
    std::function<void(const std::string& wavPath, const std::string& error)> onTranscriptionError;
    std::function<void()> onReady;
    std::function<void(double)> onDownloadProgress;
    std::function<void()> onDownloadStarted;

private:
    bool loadModel();
    void downloadModel();
    void releaseDownloadSession();
    std::string getModelPath() const;
    std::string getModelUrl() const;
    void doTranscribe(std::string wavFilePath);

    whisper_context *m_ctx = nullptr;
    std::mutex m_mutex;
    std::atomic<bool> m_isReady{false};
    std::atomic<bool> m_isTranscribing{false};
    bool m_isDownloading = false;
    double m_downloadProgress = 0.0;
    void *m_downloadSession = nullptr;
};
