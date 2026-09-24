#pragma once
#include "appcontroller.h"
#include <dispatch/dispatch.h>
#include <string>

#ifdef __OBJC__
@class NSStatusItem;
@class NSMenu;
@class NSMenuItem;
@class StatusBarDelegate;
#else
typedef void NSStatusItem;
typedef void NSMenu;
typedef void NSMenuItem;
typedef void StatusBarDelegate;
#endif

class StatusBarController {
public:
    StatusBarController(AppController *controller);
    ~StatusBarController();

    void setup();

private:
    void updateIcon(AppController::State state);
    void updateStatusText(const std::string& text);
    void updateLocalModelToggle();
    // Transcription phase text with a running "· Ns" suffix so a slow upload reads as
    // progress instead of a hang.
    void showPhase(const std::string& text, bool restartClock);
    void renderPhase();
    void startClock();
    void stopClock();

    AppController *m_controller;
    NSStatusItem *m_statusItem;
    NSMenu *m_menu;
    NSMenuItem *m_statusMenuItem;
    NSMenuItem *m_lastErrorItem;
    NSMenuItem *m_localModelItem;
    StatusBarDelegate *m_delegate;
    dispatch_source_t m_clock;
    double m_phaseStartedAt;
    std::string m_phaseText;
};
