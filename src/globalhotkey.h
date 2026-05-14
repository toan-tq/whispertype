#pragma once
#include <functional>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

class GlobalHotkey {
public:
    GlobalHotkey();
    ~GlobalHotkey();

    bool start();
    void stop();

    std::function<void()> onHotkeyPressed;

private:
    static CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type,
                                     CGEventRef event, void *refcon);
    CFMachPortRef m_eventTap = nullptr;
    CFRunLoopSourceRef m_runLoopSource = nullptr;
};
