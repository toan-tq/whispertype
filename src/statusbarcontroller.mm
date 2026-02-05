#include "statusbarcontroller.h"
#import <Cocoa/Cocoa.h>

@interface StatusBarDelegate : NSObject
@property (nonatomic, copy) void (^onQuit)(void);
- (void)quitApp:(id)sender;
@end

@implementation StatusBarDelegate
- (void)quitApp:(id)sender {
    (void)sender;
    if (self.onQuit) {
        self.onQuit();
    } else {
        [NSApp terminate:nil];
    }
}
@end

StatusBarController::StatusBarController(AppController *controller)
    : m_controller(controller)
    , m_statusItem(nil)
    , m_menu(nil)
    , m_statusMenuItem(nil)
    , m_delegate(nil)
{
}

StatusBarController::~StatusBarController()
{
    if (m_statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:m_statusItem];
    }
}

void StatusBarController::setup()
{
    m_delegate = [[StatusBarDelegate alloc] init];
    m_delegate.onQuit = ^{ [NSApp terminate:nil]; };

    m_statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    updateIcon(m_controller->state());

    m_menu = [[NSMenu alloc] init];

    m_statusMenuItem = [m_menu addItemWithTitle:@"Initializing..." action:nil keyEquivalent:@""];
    [m_statusMenuItem setEnabled:NO];

    [m_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hotkeyItem = [m_menu addItemWithTitle:@"Toggle: \u2318\u21E7V" action:nil keyEquivalent:@""];
    [hotkeyItem setEnabled:NO];

    [m_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [m_menu addItemWithTitle:@"Quit Whispertype"
                                             action:@selector(quitApp:) keyEquivalent:@"q"];
    [quitItem setTarget:m_delegate];

    m_statusItem.menu = m_menu;

    // Connect callbacks
    m_controller->onStateChanged = [this](AppController::State state) {
        updateIcon(state);
        switch (state) {
        case AppController::State::Initializing:
            updateStatusText("Initializing...");
            break;
        case AppController::State::Ready:
            updateStatusText("Ready \u2014 \u2318\u21E7V to record");
            break;
        case AppController::State::Recording:
            updateStatusText("Recording...");
            break;
        case AppController::State::Transcribing:
            updateStatusText("Transcribing...");
            break;
        }
    };

    m_controller->onDownloadProgress = [this](double progress) {
        int pct = static_cast<int>(progress * 100);
        updateStatusText("Downloading model... " + std::to_string(pct) + "%");
    };

    m_controller->onDownloadStarted = [this]() {
        updateStatusText("Downloading Whisper model...");
    };
}

void StatusBarController::updateIcon(AppController::State state)
{
    NSString *symbolName = nil;
    NSString *desc = nil;

    switch (state) {
    case AppController::State::Initializing:
        symbolName = @"mic.slash.fill"; desc = @"Initializing"; break;
    case AppController::State::Ready:
        symbolName = @"mic.fill"; desc = @"Ready"; break;
    case AppController::State::Recording:
        symbolName = @"record.circle"; desc = @"Recording"; break;
    case AppController::State::Transcribing:
        symbolName = @"ellipsis.circle.fill"; desc = @"Transcribing"; break;
    }

    NSImage *icon = [NSImage imageWithSystemSymbolName:symbolName
                              accessibilityDescription:desc];
    if (icon) {
        [icon setTemplate:YES];
        [icon setSize:NSMakeSize(18.0, 18.0)];
        m_statusItem.button.image = icon;
    }
}

void StatusBarController::updateStatusText(const std::string& text)
{
    if (m_statusMenuItem) {
        [m_statusMenuItem setTitle:[NSString stringWithUTF8String:text.c_str()]];
    }
}
