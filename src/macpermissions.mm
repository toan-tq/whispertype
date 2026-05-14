#include "macpermissions.h"
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>

bool MacPermissions::checkMicrophonePermission()
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    return status == AVAuthorizationStatusAuthorized;
}

void MacPermissions::requestMicrophonePermission(std::function<void(bool)> callback)
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];

    if (status == AVAuthorizationStatusAuthorized) {
        if (callback) callback(true);
        return;
    }

    if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (callback) callback(granted);
            });
        }];
        return;
    }

    // Denied or Restricted
    if (callback) callback(false);
}

MacPermissions::PermissionStatus MacPermissions::microphoneStatus()
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    switch (status) {
        case AVAuthorizationStatusAuthorized:
            return PermissionStatus::Granted;
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            return PermissionStatus::Denied;
        case AVAuthorizationStatusNotDetermined:
        default:
            return PermissionStatus::Undetermined;
    }
}

bool MacPermissions::checkAccessibilityPermission()
{
    return AXIsProcessTrusted();
}

void MacPermissions::requestAccessibilityPermission()
{
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}
