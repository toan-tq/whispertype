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

    std::function<void(const std::string&)> onTranscriptionComplete;
    std::function<void(const std::string&)> onTranscriptionError;
    std::function<void()> onReady;
    std::function<void(double)> onDownloadProgress;
    std::function<void()> onDownloadStarted;

private:
    bool loadModel();
    void downloadModel();
    std::string getModelPath() const;
    std::string getModelUrl() const;
    void doTranscribe(const std::string& wavFilePath);

    whisper_context *m_ctx = nullptr;
    std::mutex m_mutex;
    std::atomic<bool> m_isReady{false};
    std::atomic<bool> m_isTranscribing{false};
    bool m_isDownloading = false;
    double m_downloadProgress = 0.0;
    std::string m_pendingTranscription;
    void *m_downloadSession = nullptr;
};
