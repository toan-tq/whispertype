#include "textinjector.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <vector>

// Voice commands: each entry maps trigger phrases to a key action.
// "standalone" commands only fire when the entire transcription matches.
// "inline" commands fire when found within a sentence.
enum class CommandMode { Standalone, Inline };

struct VoiceCommand {
    NSArray<NSString *> *triggers;
    CGKeyCode keyCode;
    CGEventFlags flags;
    CommandMode mode;
    bool deleteTyped; // true = delete all previously typed chars (e.g. "xoá")
};

static NSArray<NSValue *> *voiceCommands()
{
    static NSArray<NSValue *> *commands = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static VoiceCommand cmds[] = {
            { @[@"enter"],                        kVK_Return, kCGEventFlagMaskAlternate, CommandMode::Standalone, false },
            { @[@"xuống dòng", @"new line"],      kVK_Return, kCGEventFlagMaskAlternate, CommandMode::Inline,     false },
            { @[@"tab"],                          kVK_Tab,    0,                          CommandMode::Inline,     false },
            { @[@"xoá", @"delete"],               kVK_Delete, 0,                          CommandMode::Inline,     true  },
        };
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:4];
        for (auto &c : cmds) {
            [arr addObject:[NSValue valueWithPointer:&c]];
        }
        commands = [arr copy];
    });
    return commands;
}

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

    NSString *trimmed = [nsText stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Check standalone commands first
    for (NSValue *val in voiceCommands()) {
        const VoiceCommand *cmd = (const VoiceCommand *)val.pointerValue;
        if (cmd->mode != CommandMode::Standalone) continue;
        for (NSString *trigger in cmd->triggers) {
            if ([trimmed caseInsensitiveCompare:trigger] == NSOrderedSame) {
                simulateKeyPress(cmd->keyCode, cmd->flags);
                return;
            }
        }
    }

    // Build regex from inline commands
    NSMutableArray<NSString *> *patterns = [NSMutableArray array];
    for (NSValue *val in voiceCommands()) {
        const VoiceCommand *cmd = (const VoiceCommand *)val.pointerValue;
        if (cmd->mode != CommandMode::Inline) continue;
        for (NSString *trigger in cmd->triggers) {
            [patterns addObject:[NSRegularExpression escapedPatternForString:trigger]];
        }
    }

    NSString *pattern = [NSString stringWithFormat:@"\\b(%@)\\b",
                         [patterns componentsJoinedByString:@"|"]];
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:pattern
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

        // Find and execute the matching command
        NSString *matched = [[nsText substringWithRange:[match rangeAtIndex:1]] lowercaseString];
        for (NSValue *val in voiceCommands()) {
            const VoiceCommand *cmd = (const VoiceCommand *)val.pointerValue;
            if (cmd->mode != CommandMode::Inline) continue;
            for (NSString *trigger in cmd->triggers) {
                if ([matched isEqualToString:[trigger lowercaseString]]) {
                    if (cmd->deleteTyped) {
                        for (int i = 0; i < charsTyped; i++) {
                            simulateKeyPress(cmd->keyCode, cmd->flags);
                        }
                    } else {
                        simulateKeyPress(cmd->keyCode, cmd->flags);
                    }
                    charsTyped = 0;
                    goto next_match;
                }
            }
        }
        next_match:

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
