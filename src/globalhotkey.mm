#include "globalhotkey.h"
#import <Carbon/Carbon.h>
#import <dispatch/dispatch.h>

GlobalHotkey::GlobalHotkey()
{
}

GlobalHotkey::~GlobalHotkey()
{
    stop();
}

CGEventRef GlobalHotkey::eventCallback(CGEventTapProxy proxy, CGEventType type,
                                        CGEventRef event, void *refcon)
{
    (void)proxy;
    GlobalHotkey *self = static_cast<GlobalHotkey *>(refcon);

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        NSLog(@"Event tap disabled, re-enabling...");
        if (self->m_eventTap) {
            CGEventTapEnable(self->m_eventTap, true);
        }
        return event;
    }

    if (type != kCGEventKeyDown) {
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags flags = CGEventGetFlags(event);

    bool hasOpt = (flags & kCGEventFlagMaskAlternate) != 0;

    if (keyCode == kVK_Space && hasOpt) {
        NSLog(@"Global hotkey Option+Space pressed");
        auto callback = self->onHotkeyPressed;
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback();
            });
        }
        return NULL;
    }

    return event;
}

bool GlobalHotkey::start()
{
    if (m_eventTap) {
        NSLog(@"Event tap already running");
        return true;
    }

    CGEventMask eventMask = (1 << kCGEventKeyDown);

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
    CFRunLoopAddSource(CFRunLoopGetMain(), m_runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(m_eventTap, true);

    NSLog(@"Global hotkey registered: Option+Space");
    return true;
}

void GlobalHotkey::stop()
{
    if (m_runLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), m_runLoopSource, kCFRunLoopCommonModes);
        CFRelease(m_runLoopSource);
        m_runLoopSource = nullptr;
    }

    if (m_eventTap) {
        CGEventTapEnable(m_eventTap, false);
        CFRelease(m_eventTap);
        m_eventTap = nullptr;
    }

    NSLog(@"Global hotkey unregistered");
}
