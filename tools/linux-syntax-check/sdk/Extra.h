#pragma once
#pragma clang system_header
#include "Stub.h"
// ---- CoreAudio / AudioToolbox
typedef UInt32 AudioFormatID;
typedef UInt32 AudioFormatFlags;
enum { kAudioFormatLinearPCM = 'lpcm', kAudioFormatMPEG4AAC = 'aac ', kAudioFormatFLAC = 'flac' };
enum { kAudioFormatFlagIsFloat = 1, kAudioFormatFlagIsPacked = 8 };
enum { kAudioDeviceTransportTypeBuiltIn = 'bltn', kAudioDeviceTransportTypeUSB = 'usb ',
       kAudioDeviceTransportTypeBluetooth = 'blue', kAudioDeviceTransportTypeBluetoothLE = 'blea',
       kAudioDeviceTransportTypeVirtual = 'virt' };
typedef struct AudioStreamBasicDescription {
    double mSampleRate; AudioFormatID mFormatID; AudioFormatFlags mFormatFlags;
    UInt32 mBytesPerPacket; UInt32 mFramesPerPacket; UInt32 mBytesPerFrame;
    UInt32 mChannelsPerFrame; UInt32 mBitsPerChannel; UInt32 mReserved;
} AudioStreamBasicDescription;
typedef struct AudioBuffer { UInt32 mNumberChannels; UInt32 mDataByteSize; void *mData; } AudioBuffer;
typedef struct AudioBufferList { UInt32 mNumberBuffers; AudioBuffer mBuffers[1]; } AudioBufferList;
typedef struct OpaqueExtAudioFile *ExtAudioFileRef;
typedef UInt32 ExtAudioFilePropertyID;
enum { kExtAudioFileProperty_ClientDataFormat = 'cfmt', kExtAudioFileProperty_FileLengthFrames = '#frm' };
#ifdef __cplusplus
extern "C" {
#endif
OSStatus ExtAudioFileOpenURL(CFURLRef, ExtAudioFileRef *);
OSStatus ExtAudioFileDispose(ExtAudioFileRef);
OSStatus ExtAudioFileSetProperty(ExtAudioFileRef, ExtAudioFilePropertyID, UInt32, const void *);
OSStatus ExtAudioFileGetProperty(ExtAudioFileRef, ExtAudioFilePropertyID, UInt32 *, void *);
OSStatus ExtAudioFileRead(ExtAudioFileRef, UInt32 *, AudioBufferList *);
#ifdef __cplusplus
}
#endif

// ---- AVFoundation
extern NSString *const AVFormatIDKey, *const AVSampleRateKey, *const AVNumberOfChannelsKey,
    *const AVEncoderBitRateKey, *const AVEncoderAudioQualityKey, *const AVLinearPCMBitDepthKey,
    *const AVLinearPCMIsFloatKey, *const AVLinearPCMIsBigEndianKey, *const AVEncoderBitDepthHintKey;
typedef enum { AVAudioQualityHigh = 0x60 } AVAudioQuality;
typedef NSString *AVMediaType;
extern AVMediaType const AVMediaTypeAudio;
typedef enum { AVAuthorizationStatusNotDetermined = 0, AVAuthorizationStatusRestricted = 1,
               AVAuthorizationStatusDenied = 2, AVAuthorizationStatusAuthorized = 3 } AVAuthorizationStatus;
@class AVAudioRecorder;
@protocol AVAudioRecorderDelegate <NSObject> @end
@interface AVAudioRecorder : NSObject
- (instancetype)initWithURL:(NSURL *)u settings:(NSDictionary *)s error:(NSError **)e;
- (BOOL)record;
- (void)stop;
@property (readonly, getter=isRecording) BOOL recording;
@property (weak) id<AVAudioRecorderDelegate> delegate;
@property (readonly) NSTimeInterval currentTime;
@end
@interface AVCaptureDevice : NSObject
+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)t;
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)t;
+ (void)requestAccessForMediaType:(AVMediaType)t completionHandler:(void (^)(BOOL granted))h;
@property (readonly) NSString *localizedName;
@property (readonly) int32_t transportType;
@end

// ---- CoreGraphics / events
typedef uint16_t CGKeyCode;
typedef uint64_t CGEventFlags;
typedef uint64_t CGEventMask;
typedef struct __CGEvent *CGEventRef;
typedef struct __CGEventTapProxy *CGEventTapProxy;
typedef struct CGEventSource *CGEventSourceRef;
typedef enum { kCGEventKeyDown = 10, kCGEventTapDisabledByTimeout = 0xFFFFFFFE,
               kCGEventTapDisabledByUserInput = 0xFFFFFFFF } CGEventType;
typedef enum { kCGHIDEventTap = 0, kCGSessionEventTap = 1 } CGEventTapLocation;
typedef enum { kCGHeadInsertEventTap = 0 } CGEventTapPlacement;
typedef enum { kCGEventTapOptionDefault = 0 } CGEventTapOptions;
typedef enum { kCGKeyboardEventAutorepeat = 8, kCGKeyboardEventKeycode = 9 } CGEventField;
enum { kCGEventFlagMaskShift = 0x20000, kCGEventFlagMaskControl = 0x40000,
       kCGEventFlagMaskAlternate = 0x80000, kCGEventFlagMaskCommand = 0x100000 };
#define CGEventMaskBit(t) ((CGEventMask)1 << (t))
typedef CGEventRef (*CGEventTapCallBack)(CGEventTapProxy, CGEventType, CGEventRef, void *);
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef CGSize NSSize;
static inline NSSize NSMakeSize(CGFloat w, CGFloat h) { NSSize s = { w, h }; return s; }
#ifdef __cplusplus
extern "C" {
#endif
CFMachPortRef CGEventTapCreate(CGEventTapLocation, CGEventTapPlacement, CGEventTapOptions, CGEventMask, CGEventTapCallBack, void *);
void CGEventTapEnable(CFMachPortRef, bool);
int64_t CGEventGetIntegerValueField(CGEventRef, CGEventField);
CGEventFlags CGEventGetFlags(CGEventRef);
void CGEventSetFlags(CGEventRef, CGEventFlags);
CGEventRef CGEventCreateKeyboardEvent(CGEventSourceRef, CGKeyCode, bool);
void CGEventKeyboardSetUnicodeString(CGEventRef, unsigned long, const UniChar *);
void CGEventPost(CGEventTapLocation, CGEventRef);
bool AXIsProcessTrusted(void);
bool AXIsProcessTrustedWithOptions(CFDictionaryRef);
extern CFStringRef kAXTrustedCheckOptionPrompt;
#ifdef __cplusplus
}
#endif
enum { kVK_Return = 0x24, kVK_Tab = 0x30, kVK_Space = 0x31, kVK_Delete = 0x33 };

// ---- AppKit
typedef enum { NSApplicationActivationPolicyAccessory = 1 } NSApplicationActivationPolicy;
typedef NSInteger NSControlStateValue;
enum { NSControlStateValueOff = 0, NSControlStateValueOn = 1 };
#define NSVariableStatusItemLength (-1.0)
@interface NSApplication : NSObject
+ (NSApplication *)sharedApplication;
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)p;
- (void)run;
- (void)terminate:(id)s;
@end
extern NSApplication *NSApp;
@interface NSImage : NSObject
+ (instancetype)imageWithSystemSymbolName:(NSString *)n accessibilityDescription:(NSString *)d;
- (void)setTemplate:(BOOL)t;
- (void)setSize:(NSSize)s;
@end
@interface NSStatusBarButton : NSObject
@property (strong) NSImage *image;
@end
@class NSMenu;
@interface NSMenuItem : NSObject
+ (NSMenuItem *)separatorItem;
- (void)setEnabled:(BOOL)e;
- (void)setHidden:(BOOL)h;
- (void)setTarget:(id)t;
- (void)setState:(NSControlStateValue)s;
- (void)setTitle:(NSString *)t;
@end
@interface NSMenu : NSObject
- (NSMenuItem *)addItemWithTitle:(NSString *)t action:(SEL)a keyEquivalent:(NSString *)k;
- (void)addItem:(NSMenuItem *)i;
@end
@interface NSStatusItem : NSObject
@property (readonly, strong) NSStatusBarButton *button;
@property (strong) NSMenu *menu;
@end
@interface NSStatusBar : NSObject
+ (NSStatusBar *)systemStatusBar;
- (NSStatusItem *)statusItemWithLength:(CGFloat)l;
- (void)removeStatusItem:(NSStatusItem *)i;
@end
@interface NSWorkspace : NSObject
+ (NSWorkspace *)sharedWorkspace;
- (BOOL)openURL:(NSURL *)u;
@end
#ifdef __cplusplus
extern "C" {
#endif
void NSBeep(void);
#ifdef __cplusplus
}
#endif
