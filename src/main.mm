#import <Cocoa/Cocoa.h>
#include "appcontroller.h"
#include "statusbarcontroller.h"
#include "globalhotkey.h"
#include "macpermissions.h"

int main(int argc, const char *argv[])
{
    (void)argc; (void)argv;

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        AppController controller;
        StatusBarController statusBar(&controller);
        statusBar.setup();

        GlobalHotkey hotkey;
        hotkey.onHotkeyPressed = [&controller]() {
            controller.toggleRecording();
        };

        // Request accessibility permission and start hotkey with retry
        if (!MacPermissions::checkAccessibilityPermission()) {
            MacPermissions::requestAccessibilityPermission();
        }

        if (!hotkey.start()) {
            NSLog(@"Waiting for Accessibility permission...");
            dispatch_source_t retryTimer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(retryTimer,
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 0);
            GlobalHotkey *hotkeyPtr = &hotkey;
            dispatch_source_set_event_handler(retryTimer, ^{
                if (hotkeyPtr->start()) {
                    dispatch_source_cancel(retryTimer);
                }
            });
            dispatch_resume(retryTimer);
        }

        [NSApp run];
    }

    return 0;
}
