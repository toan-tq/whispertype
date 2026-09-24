#include "voicerecorder.h"
#include "macpermissions.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

// Recording format. WAV (16 kHz 16-bit PCM) is the default: it is what Groq's Whisper
// was validated on for Vietnamese, and a real-voice test on 2026-09-24 found FLAC from
// AVAudioRecorder both larger than WAV (~33 KB/s) and worse in transcript quality, while
// AAC at any bitrate changed words. The alternatives stay available as an opt-in for
// experiments: defaults write com.tqt.whispertype RecordingFormat -string flac
static NSString *const kRecordingFormatKey = @"RecordingFormat";
static const double kSampleRate = 16000.0;
static const int kAACBitRate = 48000;

// Auto-stop cap. Override: defaults write com.tqt.whispertype MaxRecordingSeconds -int 60
static NSString *const kMaxRecordingSecondsKey = @"MaxRecordingSeconds";
static const NSInteger kDefaultMaxRecordingSeconds = 30;
static const NSInteger kMinRecordingSeconds = 5;
static const NSInteger kMaxRecordingSeconds = 600;

// Recordings left behind (crash, or kept after a failed transcription) are removed after this.
static const NSTimeInterval kPurgeAfterSeconds = 7 * 24 * 3600;

static NSTimeInterval monotonicNow() { return [NSProcessInfo processInfo].systemUptime; }

@interface VoiceRecorderHelper : NSObject <AVAudioRecorderDelegate>
@property (nonatomic, copy) void (^onFinished)(std::string path);
@property (nonatomic, copy) void (^onError)(std::string error);
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) NSTimeInterval maxDuration;
@property (nonatomic, copy) NSString *currentPath;
@end

@implementation VoiceRecorderHelper

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    (void)recorder;
    if (flag && self.onFinished) {
        std::string path = [self.currentPath UTF8String];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onFinished(path);
        });
    } else if (self.onError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onError("Recording failed");
        });
    }
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    (void)recorder;
    [self stopTimer];
    if (self.onError) {
        std::string msg = [[error localizedDescription] UTF8String] ?: "Unknown recording error";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onError(msg);
        });
    }
}

- (void)startTimerWithStopBlock:(void(^)(void))stopBlock {
    self.startedAt = monotonicNow();
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak VoiceRecorderHelper *weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        VoiceRecorderHelper *s = weakSelf;
        if (!s) return;
        // Wall-clock based, so a busy main thread cannot stretch the cap.
        if (monotonicNow() - s.startedAt >= s.maxDuration) {
            NSLog(@"Max duration reached (%.0fs), stopping...", s.maxDuration);
            if (stopBlock) stopBlock();
        }
    });
    dispatch_resume(self.timer);
}

- (void)stopTimer {
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
}

@end

// ---

std::string VoiceRecorder::cacheDirectory()
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = [paths.firstObject stringByAppendingPathComponent:@"com.tqt.whispertype"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [cacheDir UTF8String];
}

static NSString *generateFilePath(NSString *extension)
{
    NSString *cacheDir = [NSString stringWithUTF8String:VoiceRecorder::cacheDirectory().c_str()];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss_SSS";
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    return [cacheDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"voice_%@.%@", timestamp, extension]];
}

// Recorder settings for a format name; the container type follows the file extension.
static NSDictionary *recorderSettings(NSString *format, NSString **extension)
{
    if ([format isEqualToString:@"aac"]) {
        *extension = @"m4a";
        return @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @(kSampleRate),
            AVNumberOfChannelsKey: @1,
            AVEncoderBitRateKey: @(kAACBitRate),
            AVEncoderAudioQualityKey: @(AVAudioQualityHigh),
        };
    }
    if ([format isEqualToString:@"wav"]) {
        *extension = @"wav";
        return @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(kSampleRate),
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
        };
    }
    *extension = @"flac";
    return @{
        AVFormatIDKey: @(kAudioFormatFLAC),
        AVSampleRateKey: @(kSampleRate),
        AVNumberOfChannelsKey: @1,
        AVEncoderBitDepthHintKey: @16,
    };
}

static NSString *configuredFormat()
{
    NSString *format = [[[NSUserDefaults standardUserDefaults] stringForKey:kRecordingFormatKey] lowercaseString];
    if ([format isEqualToString:@"aac"] || [format isEqualToString:@"flac"]) return format;
    return @"wav";
}

static void purgeOldFiles(NSString *dir)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kPurgeAfterSeconds];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (![[attrs fileType] isEqualToString:NSFileTypeRegular]) continue;
        NSDate *modified = [attrs fileModificationDate];
        if (modified && [modified compare:cutoff] == NSOrderedAscending) {
            [fm removeItemAtPath:path error:nil];
        }
    }
}

static NSTimeInterval configuredMaxDuration()
{
    NSInteger secs = [[NSUserDefaults standardUserDefaults] integerForKey:kMaxRecordingSecondsKey];
    if (secs <= 0) secs = kDefaultMaxRecordingSeconds;
    secs = MAX(kMinRecordingSeconds, MIN(kMaxRecordingSeconds, secs));
    return (NSTimeInterval)secs;
}

VoiceRecorder::VoiceRecorder()
{
    VoiceRecorderHelper *helper = [[VoiceRecorderHelper alloc] init];
    helper.maxDuration = configuredMaxDuration();
    m_impl = (__bridge_retained void *)helper;

    NSString *cacheDir = [NSString stringWithUTF8String:cacheDirectory().c_str()];
    purgeOldFiles(cacheDir);
    purgeOldFiles([cacheDir stringByAppendingPathComponent:@"failed"]);

    // Check mic permission
    auto status = MacPermissions::microphoneStatus();
    if (status == MacPermissions::PermissionStatus::Denied) {
        NSLog(@"Microphone permission denied!");
    } else if (status == MacPermissions::PermissionStatus::Undetermined) {
        MacPermissions::requestMicrophonePermission([](bool granted) {
            NSLog(@"Microphone permission: %s", granted ? "granted" : "denied");
        });
    }

    NSLog(@"VoiceRecorder initialized (format %@, %.0f Hz, max %.0fs)",
          configuredFormat(), kSampleRate, helper.maxDuration);
}

VoiceRecorder::~VoiceRecorder()
{
    if (m_isRecording) stopRecording();
    if (m_impl) {
        VoiceRecorderHelper *helper = (__bridge_transfer VoiceRecorderHelper *)m_impl;
        [helper stopTimer];
        helper = nil;
        m_impl = nullptr;
    }
}

void VoiceRecorder::startRecording()
{
    if (m_isRecording) return;

    VoiceRecorderHelper *helper = (__bridge VoiceRecorderHelper *)m_impl;

    // Try the configured format first; fall back to plain WAV so a format the OS
    // refuses to encode never costs a recording.
    NSString *format = configuredFormat();
    NSArray<NSString *> *attempts = [format isEqualToString:@"wav"] ? @[@"wav"] : @[format, @"wav"];
    NSError *error = nil;
    for (NSString *candidate in attempts) {
        NSString *extension = nil;
        NSDictionary *settings = recorderSettings(candidate, &extension);
        NSString *filePath = generateFilePath(extension);
        error = nil;
        AVAudioRecorder *recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:filePath]
                                                                settings:settings error:&error];
        if (!recorder || error) {
            NSLog(@"Cannot create %@ recorder: %@", candidate, error);
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
            continue;
        }
        helper.recorder = recorder;
        helper.currentPath = filePath;
        if (![candidate isEqualToString:format]) NSLog(@"Falling back to %@ recording", candidate);
        break;
    }
    if (!helper.recorder || !helper.currentPath) {
        NSLog(@"Failed to create AVAudioRecorder: %@", error);
        if (onRecordingError) onRecordingError(error ? [[error localizedDescription] UTF8String] : "Failed to init recorder");
        return;
    }

    helper.recorder.delegate = helper;

    // Wire up callbacks
    helper.onFinished = [this](std::string path) {
        m_isRecording = false;
        if (onRecordingFinished) onRecordingFinished(path);
    };
    helper.onError = [this](std::string err) {
        m_isRecording = false;
        if (onRecordingError) onRecordingError(err);
    };

    NSLog(@"Starting recording to: %@", helper.currentPath);

    if (![helper.recorder record]) {
        NSLog(@"Failed to start recording");
        [[NSFileManager defaultManager] removeItemAtPath:helper.currentPath error:nil];
        helper.recorder = nil;
        if (onRecordingError) onRecordingError("Failed to start recording");
        return;
    }

    m_isRecording = true;

    __weak VoiceRecorderHelper *weakHelper = helper;
    [helper startTimerWithStopBlock:^{
        VoiceRecorderHelper *h = weakHelper;
        if (h && h.recorder.isRecording) {
            [h stopTimer];
            [h.recorder stop];
        }
    }];
}

void VoiceRecorder::stopRecording()
{
    if (!m_isRecording) return;

    VoiceRecorderHelper *helper = (__bridge VoiceRecorderHelper *)m_impl;
    [helper stopTimer];

    if (helper.recorder.isRecording) {
        [helper.recorder stop];
    }

    // m_isRecording will be set to false in the delegate callback
}
