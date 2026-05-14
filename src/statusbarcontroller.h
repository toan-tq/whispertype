#pragma once
#include "appcontroller.h"
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

    AppController *m_controller;
    NSStatusItem *m_statusItem;
    NSMenu *m_menu;
    NSMenuItem *m_statusMenuItem;
    NSMenuItem *m_localModelItem;
    StatusBarDelegate *m_delegate;
};
