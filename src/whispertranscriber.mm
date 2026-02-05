#include "whispertranscriber.h"
#include <whisper.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <vector>

@interface DownloadHelper : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^onProgress)(double progress);
@property (nonatomic, copy) void (^onComplete)(NSString *destPath);
@property (nonatomic, copy) void (^onError)(NSString *error);
@property (nonatomic, copy) NSString *destPath;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation DownloadHelper

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (totalBytesExpectedToWrite > 0 && self.onProgress) {
        double progress = (double)totalBytesWritten / totalBytesExpectedToWrite;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onProgress(progress);
        });
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    NSError *error = nil;
    NSString *tmpPath = [self.destPath stringByAppendingString:@".tmp"];
    [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:tmpPath error:&error];
    if (error) {
        if (self.onError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.onError([error localizedDescription]);
            });
        }
        return;
    }

    // Rename to final path
    [[NSFileManager defaultManager] removeItemAtPath:self.destPath error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:tmpPath toPath:self.destPath error:&error];
    if (error) {
        if (self.onError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.onError([error localizedDescription]);
            });
        }
        return;
    }

    if (self.onComplete) {
        NSString *dest = self.destPath;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onComplete(dest);
        });
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    if (error && self.onError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onError([error localizedDescription]);
        });
    }
}

@end

// ---

WhisperTranscriber::WhisperTranscriber()
{
}

WhisperTranscriber::~WhisperTranscriber()
{
    if (m_downloadSession) {
        DownloadHelper *helper = (__bridge_transfer DownloadHelper *)m_downloadSession;
        [helper.session invalidateAndCancel];
        helper = nil;
        m_downloadSession = nullptr;
    }

    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_ctx) {
        whisper_free(m_ctx);
        m_ctx = nullptr;
    }
}

std::string WhisperTranscriber::getModelPath() const
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupport = [paths.firstObject stringByAppendingPathComponent:@"TQT/Whispertype"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appSupport
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [[appSupport stringByAppendingPathComponent:@"ggml-large-v3-turbo.bin"] UTF8String];
}

std::string WhisperTranscriber::getModelUrl() const
{
    return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
}

void WhisperTranscriber::initialize()
{
    if (m_isReady || m_isDownloading) return;

    std::string modelPath = getModelPath();
    NSString *nsPath = [NSString stringWithUTF8String:modelPath.c_str()];

    if ([[NSFileManager defaultManager] fileExistsAtPath:nsPath]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:nsPath error:nil];
        if ([attrs fileSize] > 0) {
            NSLog(@"Model found at: %@", nsPath);
            if (loadModel()) return;
        }
    }

    NSLog(@"Model not found, downloading...");
    downloadModel();
}

bool WhisperTranscriber::loadModel()
{
    std::string modelPath = getModelPath();
    NSLog(@"Loading Whisper model from: %s", modelPath.c_str());

    struct whisper_context_params cparams = whisper_context_default_params();

    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_ctx = whisper_init_from_file_with_params(modelPath.c_str(), cparams);
    }

    if (!m_ctx) {
        NSLog(@"Failed to load Whisper model");
        if (onTranscriptionError) onTranscriptionError("Failed to load Whisper model");
        return false;
    }

    m_isReady.store(true);
    if (onReady) onReady();
    NSLog(@"Whisper model loaded successfully");

    std::string pending;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        pending = m_pendingTranscription;
        m_pendingTranscription.clear();
    }
    if (!pending.empty()) {
        transcribe(pending);
    }

    return true;
}

void WhisperTranscriber::downloadModel()
{
    if (m_isDownloading) return;

    m_isDownloading = true;
    if (onDownloadStarted) onDownloadStarted();

    DownloadHelper *helper = [[DownloadHelper alloc] init];
    helper.destPath = [NSString stringWithUTF8String:getModelPath().c_str()];

    helper.onProgress = [this](double progress) {
        m_downloadProgress = progress;
        if (onDownloadProgress) onDownloadProgress(progress);
    };

    helper.onComplete = [this](NSString *path) {
        NSLog(@"Model downloaded successfully");
        m_isDownloading = false;
        m_downloadProgress = 0.0;
        loadModel();
    };

    helper.onError = [this](NSString *error) {
        NSLog(@"Download failed: %@", error);
        m_isDownloading = false;
        m_downloadProgress = 0.0;
        if (onTranscriptionError) onTranscriptionError([[NSString stringWithFormat:@"Download failed: %@", error] UTF8String]);
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    helper.session = [NSURLSession sessionWithConfiguration:config delegate:helper delegateQueue:nil];

    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:getModelUrl().c_str()]];
    NSURLSessionDownloadTask *task = [helper.session downloadTaskWithURL:url];
    [task resume];

    m_downloadSession = (__bridge_retained void *)helper;

    NSLog(@"Downloading Whisper model from: %s", getModelUrl().c_str());
}

void WhisperTranscriber::transcribe(const std::string& wavFilePath)
{
    if (m_isTranscribing.load()) {
        NSLog(@"Already transcribing");
        return;
    }

    if (!m_isReady.load()) {
        NSLog(@"Model not ready, queuing transcription");
        std::lock_guard<std::mutex> lock(m_mutex);
        m_pendingTranscription = wavFilePath;
        initialize();
        return;
    }

    m_isTranscribing.store(true);

    std::string path = wavFilePath;  // copy — reference dangles after dispatch
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        doTranscribe(path);
    });
}

void WhisperTranscriber::doTranscribe(const std::string& wavFilePath)
{
    NSLog(@"Starting transcription of: %s", wavFilePath.c_str());

    // Read audio file using ExtAudioFile (handles any WAV format)
    NSString *nsPath = [NSString stringWithUTF8String:wavFilePath.c_str()];
    NSURL *fileURL = [NSURL fileURLWithPath:nsPath];

    ExtAudioFileRef audioFile = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile);
    if (status != noErr || !audioFile) {
        dispatch_async(dispatch_get_main_queue(), ^{
            m_isTranscribing.store(false);
            if (onTranscriptionError) onTranscriptionError("Failed to open audio file");
        });
        return;
    }

    // Output format: 16kHz mono float32 (what whisper expects)
    AudioStreamBasicDescription outFmt = {};
    outFmt.mSampleRate = 16000;
    outFmt.mFormatID = kAudioFormatLinearPCM;
    outFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    outFmt.mBitsPerChannel = 32;
    outFmt.mChannelsPerFrame = 1;
    outFmt.mBytesPerFrame = 4;
    outFmt.mFramesPerPacket = 1;
    outFmt.mBytesPerPacket = 4;
    ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(outFmt), &outFmt);

    // Get total frames
    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);

    if (totalFrames <= 0) {
        ExtAudioFileDispose(audioFile);
        dispatch_async(dispatch_get_main_queue(), ^{
            m_isTranscribing.store(false);
            if (onTranscriptionError) onTranscriptionError("No audio data in file");
        });
        return;
    }

    // Read all data as float32
    std::vector<float> pcmf32(totalFrames);
    AudioBufferList bufList;
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mDataByteSize = (UInt32)(totalFrames * sizeof(float));
    bufList.mBuffers[0].mNumberChannels = 1;
    bufList.mBuffers[0].mData = pcmf32.data();

    UInt32 frameCount = (UInt32)totalFrames;
    ExtAudioFileRead(audioFile, &frameCount, &bufList);
    ExtAudioFileDispose(audioFile);

    pcmf32.resize(frameCount);

    // Whisper parameters
    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_realtime = false;
    wparams.print_progress = false;
    wparams.print_timestamps = false;
    wparams.print_special = false;
    wparams.single_segment = true;
    wparams.no_context = true;
    wparams.language = "auto";

    int result;
    std::string transcription;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!m_ctx) {
            dispatch_async(dispatch_get_main_queue(), ^{
                m_isTranscribing.store(false);
                if (onTranscriptionError) onTranscriptionError("Whisper context not available");
            });
            return;
        }

        result = whisper_full(m_ctx, wparams, pcmf32.data(), (int)pcmf32.size());

        if (result == 0) {
            int numSegments = whisper_full_n_segments(m_ctx);
            for (int i = 0; i < numSegments; i++) {
                const char *text = whisper_full_get_segment_text(m_ctx, i);
                if (text) {
                    // Trim
                    NSString *seg = [[NSString stringWithUTF8String:text]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (seg.length > 0) {
                        if (!transcription.empty()) transcription += " ";
                        transcription += [seg UTF8String];
                    }
                }
            }
        }
    }

    if (result != 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            m_isTranscribing.store(false);
            if (onTranscriptionError) onTranscriptionError("Whisper inference failed");
        });
        return;
    }

    NSLog(@"Transcription result: %s", transcription.c_str());

    dispatch_async(dispatch_get_main_queue(), ^{
        m_isTranscribing.store(false);
        if (onTranscriptionComplete) onTranscriptionComplete(transcription);
    });
}
