#include "statusbarcontroller.h"
#include "voicerecorder.h"
#import <Cocoa/Cocoa.h>

@interface StatusBarDelegate : NSObject
@property (nonatomic, copy) void (^onQuit)(void);
@property (nonatomic, copy) void (^onToggleLocalModel)(void);
@property (nonatomic, copy) void (^onShowFailed)(void);
- (void)quitApp:(id)sender;
- (void)toggleLocalModel:(id)sender;
- (void)showFailedRecordings:(id)sender;
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

- (void)toggleLocalModel:(id)sender {
    (void)sender;
    if (self.onToggleLocalModel) {
        self.onToggleLocalModel();
    }
}

- (void)showFailedRecordings:(id)sender {
    (void)sender;
    if (self.onShowFailed) {
        self.onShowFailed();
    }
}
@end

static double monotonicNow() { return [NSProcessInfo processInfo].systemUptime; }

StatusBarController::StatusBarController(AppController *controller)
    : m_controller(controller)
    , m_statusItem(nil)
    , m_menu(nil)
    , m_statusMenuItem(nil)
    , m_lastErrorItem(nil)
    , m_localModelItem(nil)
    , m_delegate(nil)
    , m_clock(nil)
    , m_phaseStartedAt(0)
{
}

StatusBarController::~StatusBarController()
{
    stopClock();
    if (m_statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:m_statusItem];
    }
}

void StatusBarController::setup()
{
    m_delegate = [[StatusBarDelegate alloc] init];
    m_delegate.onQuit = ^{ [NSApp terminate:nil]; };
    m_delegate.onToggleLocalModel = ^{
        bool newState = !m_controller->isLocalModelEnabled();
        m_controller->setLocalModelEnabled(newState);
        updateLocalModelToggle();
    };
    m_delegate.onShowFailed = ^{
        NSString *dir = [[NSString stringWithUTF8String:VoiceRecorder::cacheDirectory().c_str()]
                         stringByAppendingPathComponent:@"failed"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
    };

    m_statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    updateIcon(m_controller->state());

    m_menu = [[NSMenu alloc] init];

    m_statusMenuItem = [m_menu addItemWithTitle:@"Initializing..." action:nil keyEquivalent:@""];
    [m_statusMenuItem setEnabled:NO];

    m_lastErrorItem = [m_menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    [m_lastErrorItem setEnabled:NO];
    [m_lastErrorItem setHidden:YES];

    [m_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hotkeyItem = [m_menu addItemWithTitle:@"Toggle: ⌥ Space" action:nil keyEquivalent:@""];
    [hotkeyItem setEnabled:NO];

    [m_menu addItem:[NSMenuItem separatorItem]];

    m_localModelItem = [m_menu addItemWithTitle:@"Local Model (fallback)"
                                         action:@selector(toggleLocalModel:) keyEquivalent:@""];
    [m_localModelItem setTarget:m_delegate];
    updateLocalModelToggle();

    NSMenuItem *failedItem = [m_menu addItemWithTitle:@"Show Failed Recordings"
                                               action:@selector(showFailedRecordings:) keyEquivalent:@""];
    [failedItem setTarget:m_delegate];

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
            stopClock();
            updateStatusText("Set GroqAPIKey in defaults");
            break;
        case AppController::State::Ready:
            stopClock();
            updateStatusText("Ready — ⌥Space to record");
            break;
        case AppController::State::Recording:
            stopClock();
            updateStatusText("Recording...");
            break;
        case AppController::State::Transcribing:
            showPhase("Transcribing", true);
            break;
        }
    };

    m_controller->onStatusMessage = [this](const std::string& text, bool newItem) {
        // While the mic is live the menu shows "Recording..."; progress of the request
        // still in flight would only be confusing there.
        if (m_controller->state() != AppController::State::Transcribing) return;
        showPhase(text, newItem);
    };

    m_controller->onTranscriptionFailed = [this](const std::string& reason) {
        NSBeep();
        [m_lastErrorItem setTitle:[NSString stringWithFormat:@"Last error: %s (audio kept)", reason.c_str()]];
        [m_lastErrorItem setHidden:NO];
    };

    m_controller->onTranscriptionSucceeded = [this]() {
        [m_lastErrorItem setHidden:YES];
    };

    m_controller->onHotkeyIgnored = [this](const std::string& reason) {
        NSBeep();
        updateStatusText(reason);
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

void StatusBarController::updateLocalModelToggle()
{
    if (m_localModelItem) {
        [m_localModelItem setState:m_controller->isLocalModelEnabled() ? NSControlStateValueOn : NSControlStateValueOff];
    }
}

void StatusBarController::showPhase(const std::string& text, bool restartClock)
{
    m_phaseText = text;
    if (restartClock || !m_clock) m_phaseStartedAt = monotonicNow();
    startClock();
    renderPhase();
}

void StatusBarController::renderPhase()
{
    double elapsed = monotonicNow() - m_phaseStartedAt;
    std::string text = m_phaseText;
    if (elapsed >= 1.0) text += " · " + std::to_string(static_cast<int>(elapsed)) + "s";
    updateStatusText(text);
}

void StatusBarController::startClock()
{
    if (m_clock) return;
    m_clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(m_clock, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(m_clock, ^{ renderPhase(); });
    dispatch_resume(m_clock);
}

void StatusBarController::stopClock()
{
    if (!m_clock) return;
    dispatch_source_cancel(m_clock);
    m_clock = nil;
    m_phaseText.clear();
}
