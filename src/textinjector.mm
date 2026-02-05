#include "textinjector.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <vector>

static void simulateKeyPress(CGKeyCode keyCode, CGEventFlags flags = 0)
{
    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, keyCode, false);

    if (flags) {
        CGEventSetFlags(keyDown, flags);
        CGEventSetFlags(keyUp, flags);
    }

    CGEventPost(kCGSessionEventTap, keyDown);
    CGEventPost(kCGSessionEventTap, keyUp);

    CFRelease(keyDown);
    CFRelease(keyUp);

    usleep(2000);
}

static void typeUnicodeString(NSString *text)
{
    if (text.length == 0) return;

    const int chunkSize = 20;
    std::vector<UniChar> buffer(text.length);

    [text getCharacters:buffer.data() range:NSMakeRange(0, text.length)];

    for (int offset = 0; offset < (int)buffer.size(); offset += chunkSize) {
        int len = std::min(chunkSize, (int)buffer.size() - offset);

        CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, 0, false);

        CGEventKeyboardSetUnicodeString(keyDown, len, &buffer[offset]);
        CGEventKeyboardSetUnicodeString(keyUp, len, &buffer[offset]);

        CGEventPost(kCGSessionEventTap, keyDown);
        CGEventPost(kCGSessionEventTap, keyUp);

        CFRelease(keyDown);
        CFRelease(keyUp);

        usleep(2000);
    }
}

bool TextInjector::hasPermission()
{
    return AXIsProcessTrusted();
}

void TextInjector::typeText(const std::string& text)
{
    if (text.empty()) return;

    NSString *nsText = [NSString stringWithUTF8String:text.c_str()];
    if (!nsText) return;

    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"\\b(enter|xuống dòng|tab|xoá)\\b"
        options:NSRegularExpressionCaseInsensitive
        error:nil];

    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:nsText
        options:0 range:NSMakeRange(0, nsText.length)];

    int lastEnd = 0;
    int charsTyped = 0;

    for (NSTextCheckingResult *match in matches) {
        NSRange matchRange = [match rangeAtIndex:0];
        int start = (int)matchRange.location;

        // Type text before the command
        if (start > lastEnd) {
            NSString *segment = [[nsText substringWithRange:NSMakeRange(lastEnd, start - lastEnd)]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (segment.length > 0) {
                typeUnicodeString(segment);
                charsTyped += (int)segment.length;
                usleep(2000);
            }
        }

        // Execute the command
        NSString *command = [[nsText substringWithRange:[match rangeAtIndex:1]] lowercaseString];
        if ([command isEqualToString:@"enter"]) {
            simulateKeyPress(kVK_Return);
            charsTyped = 0;
        } else if ([command isEqualToString:@"xuống dòng"]) {
            simulateKeyPress(kVK_Return, kCGEventFlagMaskAlternate);
            charsTyped = 0;
        } else if ([command isEqualToString:@"tab"]) {
            simulateKeyPress(kVK_Tab);
            charsTyped = 0;
        } else if ([command isEqualToString:@"xoá"]) {
            for (int i = 0; i < charsTyped; i++) {
                simulateKeyPress(kVK_Delete);
            }
            charsTyped = 0;
        }

        usleep(2000);
        lastEnd = (int)(matchRange.location + matchRange.length);
    }

    // Type remaining text after last command
    if (lastEnd < (int)nsText.length) {
        NSString *remaining = [[nsText substringFromIndex:lastEnd]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (remaining.length > 0) {
            typeUnicodeString(remaining);
        }
    }
}
