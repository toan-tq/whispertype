#pragma once
#include <functional>

class MacPermissions {
public:
    enum class PermissionStatus { Undetermined, Granted, Denied };

    static bool checkMicrophonePermission();
    static void requestMicrophonePermission(std::function<void(bool)> callback);
    static PermissionStatus microphoneStatus();

    static bool checkAccessibilityPermission();
    static void requestAccessibilityPermission();
};
