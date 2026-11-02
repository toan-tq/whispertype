#pragma once
#include <dispatch/dispatch.h>
#include <functional>
#include <string>

struct whisper_context;

// Local transcription with whisper.cpp. The public methods are main-thread only. All work on
// the whisper context (load, inference, free) runs in order on one serial background queue,
// so the main thread — and with it the menu bar — never waits for the model.
class WhisperTranscriber {
public:
    WhisperTranscriber();
    ~WhisperTranscriber();

    // Load the model, downloading it first if it is missing. Asynchronous; onReady fires
    // once it can transcribe.
    void initialize();
    // Free the model (and cancel a download in progress): the local model was switched off.
    void release();
    void transcribe(const std::string& wavFilePath);
    bool isReady() const { return m_isReady; }
    bool isDownloading() const { return m_isDownloading; }
    double downloadProgress() const { return m_downloadProgress; }
    // File name of the configured model, e.g. "ggml-large-v3-turbo.bin".
    std::string modelName() const;

    std::function<void(const std::string& wavPath, const std::string& text)> onTranscriptionComplete;
    std::function<void(const std::string& wavPath, const std::string& error)> onTranscriptionError;
    std::function<void()> onReady;
    std::function<void(double)> onDownloadProgress;
    std::function<void()> onDownloadStarted;
    // The model could not be downloaded or loaded; the local model stays unavailable.
    std::function<void(const std::string& error)> onLoadFailed;

private:
    void loadModelAsync();
    void downloadModel();
    void releaseDownloadSession();
    std::string getModelPath() const;
    std::string getModelUrl() const;
    void doTranscribe(const std::string& wavFilePath);  // on m_queue
    void postError(std::string wavFilePath, std::string error);

    whisper_context *m_ctx = nullptr;   // only touched on m_queue
    dispatch_queue_t m_queue;
    unsigned m_loadGeneration = 0;      // bumped by release(); stale loads are discarded
    bool m_isLoading = false;
    bool m_isReady = false;
    bool m_isTranscribing = false;
    bool m_isDownloading = false;
    double m_downloadProgress = 0.0;
    void *m_downloadSession = nullptr;
};
