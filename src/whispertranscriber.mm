#include "whispertranscriber.h"
#include <whisper.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <vector>

// Which model the local engine loads. A bare file name lives in the app's model folder
// (~/Library/Application Support/TQT/Whispertype/); an absolute path is used as is.
//   defaults write com.tqt.whispertype LocalModelFile -string ggml-large-v3-turbo-q5_0.bin
// Missing files are downloaded from LocalModelURL, or else from the whisper.cpp model repo
// on Hugging Face under the same file name.
static NSString *const kLocalModelFileKey = @"LocalModelFile";
static NSString *const kLocalModelURLKey = @"LocalModelURL";
static NSString *const kDefaultModelFile = @"ggml-large-v3-turbo.bin";
static NSString *const kModelRepoURL = @"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

static double monotonicNow() { return [NSProcessInfo processInfo].systemUptime; }
static std::string cstr(NSString *s) { const char *c = [s UTF8String]; return c ? c : ""; }

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
    // An error page (404 for a mistyped LocalModelFile, 5xx) also "finishes downloading";
    // saved as the model it would fail to load on every launch.
    NSHTTPURLResponse *http = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (http && http.statusCode != 200) {
        NSString *msg = [NSString stringWithFormat:@"Model download failed: HTTP %ld", (long)http.statusCode];
        if (self.onError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.onError(msg);
            });
        }
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSString *tmpPath = [self.destPath stringByAppendingString:@".tmp"];
    // A .tmp left behind by an interrupted earlier attempt would make the move fail forever.
    [fm removeItemAtPath:tmpPath error:nil];
    [fm moveItemAtPath:location.path toPath:tmpPath error:&error];
    if (error) {
        if (self.onError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.onError([error localizedDescription]);
            });
        }
        return;
    }

    // Rename to final path
    [fm removeItemAtPath:self.destPath error:nil];
    [fm moveItemAtPath:tmpPath toPath:self.destPath error:&error];
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
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    m_queue = dispatch_queue_create("com.tqt.whispertype.whisper", attr);
}

WhisperTranscriber::~WhisperTranscriber()
{
    releaseDownloadSession();
    // Waits for an inference in progress; only reached at teardown.
    dispatch_sync(m_queue, ^{
        if (m_ctx) {
            whisper_free(m_ctx);
            m_ctx = nullptr;
        }
    });
}

void WhisperTranscriber::releaseDownloadSession()
{
    if (!m_downloadSession) return;
    // bridge_transfer hands the +1 retain from the void* to ARC. We clear the
    // callbacks first so any late delegate invocations don't dereference `this`
    // (we may be in the destructor). invalidateAndCancel + helper.session = nil
    // breaks the session<->delegate retain cycle so both can be freed.
    DownloadHelper *helper = (__bridge_transfer DownloadHelper *)m_downloadSession;
    m_downloadSession = nullptr;
    helper.onComplete = nil;
    helper.onError = nil;
    helper.onProgress = nil;
    [helper.session invalidateAndCancel];
    helper.session = nil;
}

static NSString *configuredModelFile()
{
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:kLocalModelFileKey];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name.length > 0 ? name : kDefaultModelFile;
}

std::string WhisperTranscriber::modelName() const
{
    return cstr([configuredModelFile() lastPathComponent]);
}

std::string WhisperTranscriber::getModelPath() const
{
    NSString *file = [configuredModelFile() stringByExpandingTildeInPath];
    if ([file isAbsolutePath]) return cstr(file);

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupport = [paths.firstObject stringByAppendingPathComponent:@"TQT/Whispertype"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appSupport
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return cstr([appSupport stringByAppendingPathComponent:[file lastPathComponent]]);
}

std::string WhisperTranscriber::getModelUrl() const
{
    NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:kLocalModelURLKey];
    if (url.length > 0) return cstr(url);
    return cstr([kModelRepoURL stringByAppendingString:[configuredModelFile() lastPathComponent]]);
}

void WhisperTranscriber::initialize()
{
    if (m_isReady || m_isLoading || m_isDownloading) return;

    std::string modelPath = getModelPath();
    NSString *nsPath = [NSString stringWithUTF8String:modelPath.c_str()];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:nsPath error:nil];
    if (attrs && [attrs fileSize] > 0) {
        NSLog(@"Model found at: %@ (%.0f MB)", nsPath, [attrs fileSize] / 1048576.0);
        loadModelAsync();
        return;
    }

    NSLog(@"Model not found, downloading...");
    downloadModel();
}

void WhisperTranscriber::release()
{
    ++m_loadGeneration;  // a load still in flight will be discarded when it lands
    m_isLoading = false;
    m_isReady = false;
    if (m_isDownloading) {
        NSLog(@"Cancelling model download");
        releaseDownloadSession();
        m_isDownloading = false;
        m_downloadProgress = 0.0;
    }
    // Queued behind any inference in progress, so that one still completes.
    dispatch_async(m_queue, ^{
        if (m_ctx) {
            whisper_free(m_ctx);
            m_ctx = nullptr;
            NSLog(@"Whisper model unloaded");
        }
    });
}

// Loading a large model takes seconds (reading ~1.6 GB, building Metal pipelines). It used
// to run on the main thread, which froze the menu bar meanwhile.
void WhisperTranscriber::loadModelAsync()
{
    m_isLoading = true;
    unsigned generation = ++m_loadGeneration;
    std::string modelPath = getModelPath();
    NSLog(@"Loading Whisper model from: %s", modelPath.c_str());

    dispatch_async(m_queue, ^{
        double t0 = monotonicNow();
        if (!m_ctx) {
            struct whisper_context_params cparams = whisper_context_default_params();
            m_ctx = whisper_init_from_file_with_params(modelPath.c_str(), cparams);
        }
        bool ok = m_ctx != nullptr;
        double seconds = monotonicNow() - t0;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != m_loadGeneration) return;  // released meanwhile
            m_isLoading = false;
            if (!ok) {
                NSLog(@"Failed to load Whisper model %s", modelPath.c_str());
                if (onLoadFailed) {
                    onLoadFailed("Cannot load " + modelName() + " (delete it to re-download)");
                }
                return;
            }
            NSLog(@"Whisper model %s loaded in %.1f s", modelName().c_str(), seconds);
            m_isReady = true;
            if (onReady) onReady();
        });
    });
}

void WhisperTranscriber::downloadModel()
{
    if (m_isDownloading) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:getModelUrl().c_str()]];
    if (!url) {
        if (onLoadFailed) onLoadFailed("Invalid LocalModelURL");
        return;
    }

    m_isDownloading = true;
    if (onDownloadStarted) onDownloadStarted();

    DownloadHelper *helper = [[DownloadHelper alloc] init];
    helper.destPath = [NSString stringWithUTF8String:getModelPath().c_str()];

    helper.onProgress = [this](double progress) {
        m_downloadProgress = progress;
        if (onDownloadProgress) onDownloadProgress(progress);
    };

    helper.onComplete = [this](NSString *path) {
        NSLog(@"Model downloaded successfully to %@", path);
        m_isDownloading = false;
        m_downloadProgress = 0.0;
        releaseDownloadSession();
        loadModelAsync();
    };

    helper.onError = [this](NSString *error) {
        NSLog(@"Download failed: %@", error);
        m_isDownloading = false;
        m_downloadProgress = 0.0;
        releaseDownloadSession();
        if (onLoadFailed) onLoadFailed(cstr(error));
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    helper.session = [NSURLSession sessionWithConfiguration:config delegate:helper delegateQueue:nil];

    NSURLSessionDownloadTask *task = [helper.session downloadTaskWithURL:url];
    [task resume];

    m_downloadSession = (__bridge_retained void *)helper;

    NSLog(@"Downloading Whisper model from: %s", getModelUrl().c_str());
}

void WhisperTranscriber::transcribe(const std::string& wavFilePath)
{
    if (!m_isReady) {
        if (onTranscriptionError) onTranscriptionError(wavFilePath, "Whisper model not ready");
        return;
    }

    if (m_isTranscribing) {
        if (onTranscriptionError) onTranscriptionError(wavFilePath, "Already transcribing");
        return;
    }

    m_isTranscribing = true;

    std::string path = wavFilePath;  // copy — reference dangles after dispatch
    dispatch_async(m_queue, ^{
        doTranscribe(path);
    });
}

// Parameters by value: the block below must capture copies, not references into the caller.
void WhisperTranscriber::postError(std::string wavFilePath, std::string error)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        m_isTranscribing = false;
        if (onTranscriptionError) onTranscriptionError(wavFilePath, error);
    });
}

void WhisperTranscriber::doTranscribe(const std::string& wavFilePathRef)
{
    std::string wavFilePath = wavFilePathRef;
    NSLog(@"Starting transcription of: %s", wavFilePath.c_str());
    double t0 = monotonicNow();

    if (!m_ctx) {
        postError(wavFilePath, "Whisper context not available");
        return;
    }

    // Read audio file using ExtAudioFile (decodes m4a/flac/wav via CoreAudio)
    NSString *nsPath = [NSString stringWithUTF8String:wavFilePath.c_str()];
    NSURL *fileURL = nsPath ? [NSURL fileURLWithPath:nsPath] : nil;

    ExtAudioFileRef audioFile = NULL;
    OSStatus status = fileURL ? ExtAudioFileOpenURL((__bridge CFURLRef)fileURL, &audioFile) : -1;
    if (status != noErr || !audioFile) {
        postError(wavFilePath, "Failed to open audio file");
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
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(outFmt), &outFmt);
    if (status != noErr) {
        ExtAudioFileDispose(audioFile);
        postError(wavFilePath, "Cannot convert audio to 16 kHz mono");
        return;
    }

    // Get total frames
    SInt64 totalFrames = 0;
    UInt32 propSize = sizeof(totalFrames);
    ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);

    if (totalFrames <= 0) {
        ExtAudioFileDispose(audioFile);
        postError(wavFilePath, "No audio data in file");
        return;
    }

    // Read all data as float32. ExtAudioFileRead may return fewer frames than asked for
    // (compressed formats), so loop until it reports the end of the file.
    std::vector<float> pcmf32((size_t)totalFrames);
    size_t framesRead = 0;
    while (framesRead < pcmf32.size()) {
        AudioBufferList bufList;
        bufList.mNumberBuffers = 1;
        bufList.mBuffers[0].mNumberChannels = 1;
        bufList.mBuffers[0].mDataByteSize = (UInt32)((pcmf32.size() - framesRead) * sizeof(float));
        bufList.mBuffers[0].mData = pcmf32.data() + framesRead;
        UInt32 frameCount = (UInt32)(pcmf32.size() - framesRead);
        if (ExtAudioFileRead(audioFile, &frameCount, &bufList) != noErr || frameCount == 0) break;
        framesRead += frameCount;
    }
    ExtAudioFileDispose(audioFile);
    pcmf32.resize(framesRead);

    if (pcmf32.empty()) {
        postError(wavFilePath, "No audio data in file");
        return;
    }

    // Whisper parameters
    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_realtime = false;
    wparams.print_progress = false;
    wparams.print_timestamps = false;
    wparams.print_special = false;
    wparams.no_timestamps = true;  // plain text is all we type; skips timestamp tokens
    wparams.single_segment = true;
    wparams.no_context = true;
    wparams.language = "vi";

    double tInfer = monotonicNow();
    int result = whisper_full(m_ctx, wparams, pcmf32.data(), (int)pcmf32.size());
    if (result != 0) {
        postError(wavFilePath, "Whisper inference failed");
        return;
    }

    std::string transcription;
    int numSegments = whisper_full_n_segments(m_ctx);
    for (int i = 0; i < numSegments; i++) {
        const char *text = whisper_full_get_segment_text(m_ctx, i);
        if (!text) continue;
        NSString *seg = [[NSString stringWithUTF8String:text]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (seg.length > 0) {
            if (!transcription.empty()) transcription += " ";
            transcription += cstr(seg);
        }
    }

    double audioSeconds = pcmf32.size() / 16000.0;
    double inferSeconds = monotonicNow() - tInfer;
    NSLog(@"Local transcription: %.1f s of audio in %.2f s (decode %.0f ms, inference %.2f s, "
          @"%.2fx real time): %s",
          audioSeconds, monotonicNow() - t0, (tInfer - t0) * 1000.0, inferSeconds,
          inferSeconds > 0 ? audioSeconds / inferSeconds : 0.0, transcription.c_str());

    dispatch_async(dispatch_get_main_queue(), ^{
        m_isTranscribing = false;
        if (onTranscriptionComplete) onTranscriptionComplete(wavFilePath, transcription);
    });
}
