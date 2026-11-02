#include "globalhotkey.h"
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <pthread.h>

// Option+Space only: with Command, Control or Shift also held it is another shortcut
// (Command+Option+Space opens a Finder search window) and is passed through untouched.
static const CGEventFlags kModifierMask = kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                                          kCGEventFlagMaskAlternate | kCGEventFlagMaskShift;

GlobalHotkey::GlobalHotkey()
{
}

GlobalHotkey::~GlobalHotkey()
{
    stop();
}

// Runs on the tap thread. Keep it trivial: macOS holds every key press in the session
// until this returns.
CGEventRef GlobalHotkey::eventCallback(CGEventTapProxy proxy, CGEventType type,
                                        CGEventRef event, void *refcon)
{
    (void)proxy;
    GlobalHotkey *self = static_cast<GlobalHotkey *>(refcon);

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self->m_eventTap) {
            CGEventTapEnable(self->m_eventTap, true);
        }
        return event;
    }

    if (type != kCGEventKeyDown) {
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keyCode != kVK_Space) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    if ((flags & kModifierMask) != kCGEventFlagMaskAlternate) return event;

    // Holding the keys a moment too long auto-repeats the key-down. Only the first one
    // toggles; the repeats are swallowed so they neither stop the recording that just
    // started nor type non-breaking spaces into the focused app.
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) == 0) {
        auto callback = self->onHotkeyPressed;
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback();
            });
        }
    }
    return NULL;
}

bool GlobalHotkey::start()
{
    if (m_eventTap) {
        NSLog(@"Event tap already running");
        return true;
    }

    CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown);

    m_eventTap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        eventMask,
        eventCallback,
        this
    );

    if (!m_eventTap) {
        NSLog(@"Failed to create event tap. Accessibility permission required.");
        return false;
    }

    m_runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, m_eventTap, 0);

    // This tap sees every key press in the login session — including the ones TextInjector
    // posts — and macOS waits for the callback before delivering them. On the main run loop,
    // anything that kept the main thread busy (loading the Whisper model, typing out a long
    // transcript, a slow microphone start) froze typing in every app until macOS timed the
    // tap out. A dedicated thread keeps the callback answering within microseconds.
    CFMachPortRef tap = m_eventTap;
    CFRunLoopSourceRef source = m_runLoopSource;
    CFRunLoopRef *loopOut = &m_tapRunLoop;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    m_tapThread = std::thread([tap, source, loopOut, ready]() {
        pthread_setname_np("com.tqt.whispertype.hotkey");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        @autoreleasepool {
            CFRunLoopRef loop = CFRunLoopGetCurrent();
            *loopOut = (CFRunLoopRef)CFRetain(loop);
            CFRunLoopAddSource(loop, source, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
            dispatch_semaphore_signal(ready);
        }
        // Returns once stop() removes the source and stops the loop.
        CFRunLoopRun();
    });
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);

    NSLog(@"Global hotkey registered: Option+Space");
    return true;
}

void GlobalHotkey::stop()
{
    if (!m_eventTap) return;

    CGEventTapEnable(m_eventTap, false);
    if (m_tapRunLoop) {
        // With its only source gone the loop has nothing left to run and returns; the
        // explicit stop covers a loop that is currently inside a callback.
        CFRunLoopRemoveSource(m_tapRunLoop, m_runLoopSource, kCFRunLoopCommonModes);
        CFRunLoopStop(m_tapRunLoop);
        CFRunLoopWakeUp(m_tapRunLoop);
    }
    if (m_tapThread.joinable()) m_tapThread.join();

    if (m_tapRunLoop) {
        CFRelease(m_tapRunLoop);
        m_tapRunLoop = nullptr;
    }
    if (m_runLoopSource) {
        CFRelease(m_runLoopSource);
        m_runLoopSource = nullptr;
    }
    CFMachPortInvalidate(m_eventTap);
    CFRelease(m_eventTap);
    m_eventTap = nullptr;

    NSLog(@"Global hotkey unregistered");
}
