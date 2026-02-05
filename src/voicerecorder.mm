#include "voicerecorder.h"
#include "macpermissions.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

@interface VoiceRecorderHelper : NSObject <AVAudioRecorderDelegate>
@property (nonatomic, copy) void (^onFinished)(std::string path);
@property (nonatomic, copy) void (^onError)(std::string error);
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) int recordingTimeMs;
@property (nonatomic, assign) int maxDurationMs;
@property (nonatomic, copy) NSString *currentPath;
@end

@implementation VoiceRecorderHelper

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
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
    if (self.onError) {
        std::string msg = [[error localizedDescription] UTF8String] ?: "Unknown recording error";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onError(msg);
        });
    }
}

- (void)startTimerWithStopBlock:(void(^)(void))stopBlock {
    self.recordingTimeMs = 0;
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              100 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(self.timer, ^{
        self.recordingTimeMs += 100;
        if (self.recordingTimeMs >= self.maxDurationMs) {
            NSLog(@"Max duration reached, stopping...");
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

static NSString *generateFilePath()
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = [paths.firstObject stringByAppendingPathComponent:@"com.tqt.whispertype"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss_SSS";
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    return [cacheDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"voice_%@.wav", timestamp]];
}

VoiceRecorder::VoiceRecorder()
{
    VoiceRecorderHelper *helper = [[VoiceRecorderHelper alloc] init];
    helper.maxDurationMs = 30000;
    m_impl = (__bridge_retained void *)helper;

    // Check mic permission
    auto status = MacPermissions::microphoneStatus();
    if (status == MacPermissions::PermissionStatus::Denied) {
        NSLog(@"Microphone permission denied!");
    } else if (status == MacPermissions::PermissionStatus::Undetermined) {
        MacPermissions::requestMicrophonePermission([](bool granted) {
            NSLog(@"Microphone permission: %s", granted ? "granted" : "denied");
        });
    }

    NSLog(@"VoiceRecorder initialized");
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
    NSString *filePath = generateFilePath();
    helper.currentPath = filePath;

    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @16000.0,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO
    };

    NSError *error = nil;
    helper.recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:filePath]
                                                  settings:settings error:&error];
    if (error || !helper.recorder) {
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

    NSLog(@"Starting recording to: %@", filePath);

    if (![helper.recorder record]) {
        NSLog(@"Failed to start recording");
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
