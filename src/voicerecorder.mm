#include "voicerecorder.h"
#include "macpermissions.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
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

// AVAudioRecorder reports the end of a recording through its delegate right after -stop.
// If that never arrives (the recorder had already stopped on its own, e.g. the input device
// went away), the recording is finished by hand after this long so the app cannot stay
// stuck in "Recording" with a hotkey that no longer does anything.
static const NSTimeInterval kStopWatchdogSeconds = 1.5;

static NSTimeInterval monotonicNow() { return [NSProcessInfo processInfo].systemUptime; }

@interface VoiceRecorderHelper : NSObject <AVAudioRecorderDelegate>
// Called on the main thread with the recorder it concerns; nil error means success.
@property (nonatomic, copy) void (^onFinished)(AVAudioRecorder *recorder, NSString *error);
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) NSTimeInterval maxDuration;
@property (nonatomic, copy) NSString *currentPath;
@end

@implementation VoiceRecorderHelper

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onFinished) self.onFinished(recorder, flag ? nil : @"Recording failed");
    });
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    NSString *msg = error.localizedDescription ?: @"Unknown recording error";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onFinished) self.onFinished(recorder, msg);
    });
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

static std::string cstr(NSString *s) { const char *c = [s UTF8String]; return c ? c : ""; }

static unsigned long long fileSize(NSString *path)
{
    if (!path) return 0;
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
}

// "MacBook Pro Microphone (built-in)". Logged with every recording: a Bluetooth headset
// as input is a common cause of a slow start (the headset has to switch to its call
// profile first, which takes a second or two and drops the first words) and of worse
// transcripts (narrowband audio).
static NSString *inputDeviceDescription(bool *isBluetooth)
{
    *isBluetooth = false;
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!dev) return @"no input device";
    UInt32 transport = (UInt32)dev.transportType;
    NSString *kind = @"other";
    if (transport == kAudioDeviceTransportTypeBuiltIn) kind = @"built-in";
    else if (transport == kAudioDeviceTransportTypeUSB) kind = @"USB";
    else if (transport == kAudioDeviceTransportTypeBluetooth ||
             transport == kAudioDeviceTransportTypeBluetoothLE) {
        kind = @"Bluetooth";
        *isBluetooth = true;
    } else if (transport == kAudioDeviceTransportTypeVirtual) kind = @"virtual";
    return [NSString stringWithFormat:@"%@ (%@)", dev.localizedName, kind];
}

VoiceRecorder::VoiceRecorder()
{
    VoiceRecorderHelper *helper = [[VoiceRecorderHelper alloc] init];
    helper.maxDuration = configuredMaxDuration();
    helper.onFinished = ^(AVAudioRecorder *recorder, NSString *error) {
        VoiceRecorderHelper *h = (__bridge VoiceRecorderHelper *)m_impl;
        // A late callback from an earlier recording must not end the current one.
        if (!h || recorder != h.recorder) return;
        finish(error == nil, cstr(error));
    };
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
    if (m_impl) {
        VoiceRecorderHelper *helper = (__bridge_transfer VoiceRecorderHelper *)m_impl;
        m_impl = nullptr;
        [helper stopTimer];
        helper.onFinished = nil;
        helper.recorder.delegate = nil;
        if (helper.recorder.isRecording) [helper.recorder stop];
        helper = nil;
    }
}

bool VoiceRecorder::startRecording()
{
    if (m_isRecording) return true;

    VoiceRecorderHelper *helper = (__bridge VoiceRecorderHelper *)m_impl;
    NSTimeInterval t0 = monotonicNow();

    // Never reuse the previous recording's recorder: if creating a new one fails below,
    // the old one (stopped, its file already deleted) must not be restarted.
    helper.recorder = nil;
    helper.currentPath = nil;

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
        if (onRecordingError) onRecordingError(error ? cstr([error localizedDescription]) : "Failed to init recorder");
        return false;
    }

    helper.recorder.delegate = helper;

    if (![helper.recorder record]) {
        NSLog(@"Failed to start recording (microphone unavailable or permission denied)");
        helper.recorder.delegate = nil;
        [[NSFileManager defaultManager] removeItemAtPath:helper.currentPath error:nil];
        helper.recorder = nil;
        helper.currentPath = nil;
        if (onRecordingError) onRecordingError("Microphone could not be started");
        return false;
    }

    m_isRecording = true;
    m_stopRequestedAt = 0;

    bool bluetooth = false;
    NSString *device = inputDeviceDescription(&bluetooth);
    NSLog(@"Recording started in %.0f ms from %@ to %@",
          (monotonicNow() - t0) * 1000.0, device, helper.currentPath.lastPathComponent);
    if (bluetooth) {
        NSLog(@"Input is a Bluetooth microphone: expect a slow start, clipped first words and "
              @"lower accuracy. Prefer the built-in microphone (System Settings > Sound > Input).");
    }

    [helper startTimerWithStopBlock:^{ stopRecording(); }];
    return true;
}

void VoiceRecorder::stopRecording()
{
    if (!m_isRecording) return;

    VoiceRecorderHelper *helper = (__bridge VoiceRecorderHelper *)m_impl;
    [helper stopTimer];
    if (m_stopRequestedAt > 0) return;  // already stopping; the watchdog is armed
    m_stopRequestedAt = monotonicNow();

    AVAudioRecorder *recorder = helper.recorder;
    if (recorder.isRecording) {
        NSLog(@"Stopping recording after %.1f s", recorder.currentTime);
        [recorder stop];
    } else {
        NSLog(@"Recorder had already stopped on its own");
    }

    // Normally the delegate finishes the recording within milliseconds (see finish()).
    __weak AVAudioRecorder *weakRecorder = recorder;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStopWatchdogSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VoiceRecorderHelper *h = (__bridge VoiceRecorderHelper *)m_impl;
        AVAudioRecorder *r = weakRecorder;
        if (!m_isRecording || !h || !r || h.recorder != r) return;
        NSLog(@"Recorder did not report the end of the recording within %.1fs; finishing it anyway",
              kStopWatchdogSeconds);
        if (r.isRecording) [r stop];
        // 4 KB is more than a WAV/M4A header: something was actually recorded.
        bool hasAudio = fileSize(h.currentPath) > 4096;
        finish(hasAudio, "Recording did not finish");
    });
}

void VoiceRecorder::finish(bool ok, const std::string& error)
{
    if (!m_isRecording) return;

    VoiceRecorderHelper *helper = (__bridge VoiceRecorderHelper *)m_impl;
    [helper stopTimer];
    m_isRecording = false;

    NSString *path = helper.currentPath;
    AVAudioRecorder *recorder = helper.recorder;
    recorder.delegate = nil;
    if (recorder.isRecording) [recorder stop];  // encode error: make sure the mic is released
    helper.recorder = nil;

    unsigned long long bytes = fileSize(path);
    double stopToFile = m_stopRequestedAt > 0 ? (monotonicNow() - m_stopRequestedAt) * 1000.0 : 0;
    m_stopRequestedAt = 0;

    if (ok) {
        NSLog(@"Recording finished: %@, %.0f KB, file ready %.0f ms after stop",
              path.lastPathComponent, bytes / 1024.0, stopToFile);
        if (onRecordingFinished) onRecordingFinished(cstr(path));
    } else {
        NSLog(@"Recording failed: %s (%@, %.0f KB)", error.c_str(), path.lastPathComponent, bytes / 1024.0);
        if (onRecordingError) onRecordingError(error.empty() ? "Recording failed" : error);
    }
}
