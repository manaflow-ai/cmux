// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#import "helpers.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#import <ImageIO/ImageIO.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#else
#import <CoreServices/CoreServices.h>
#endif

#define JSON_NULL @"null";

void printOut(NSString *message) {
    fprintf(stdout, "%s\n", [message UTF8String]);
    fflush(stdout);
}

void printOutUnique(NSString *message) {
    static NSString *previous = nil;
    if (![previous isEqualToString:message]) {
        printOut(message);
        previous = [message copy];
    }
}

void printErr(NSString *message) {
    fprintf(stderr, "%s\n", [message UTF8String]);
    fflush(stderr);
}

void printErrf(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *formattedMessage = [[NSString alloc] initWithFormat:format
                                                        arguments:args];
    va_end(args);
    fprintf(stderr, "%s\n", [formattedMessage UTF8String]);
    fflush(stderr);
}

void fail(NSString *message) {
    printErr(message);
    exit(1);
}

void failf(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *formattedMessage = [[NSString alloc] initWithFormat:format
                                                        arguments:args];
    va_end(args);
    fail(formattedMessage);
}

NSString *formatError(NSError *error) {
    return
        [NSString stringWithFormat:@"%@ (%@:%ld)", [error localizedDescription],
                                   [error domain], (long)[error code]];
}

static id sanitizeValueForJsonEncoding(id value, NSString *parentKey) {
    const id unsupported_type = nil; // remove silently at call site with log
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)value;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (id key in dictionary) {
            if (![key isKindOfClass:[NSString class]]) {
                printErrf(@"Invalid JSON key in dictionary: %@ (%@)",
                          [key description], [key class]);
                continue;
            }
            id raw = [dictionary objectForKey:key];
            id clean = sanitizeValueForJsonEncoding(raw, key);
            if (clean) {
                result[key] = clean;
            } else {
                printErrf(@"Invalid JSON value type in dictionary for key "
                          @"'%@': %@ (%@)",
                          key, raw, [raw class]);
            }
        }
        return result;
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        NSMutableArray *result = [NSMutableArray array];
        for (NSUInteger i = 0; i < array.count; i++) {
            id elem = array[i];
            id clean = sanitizeValueForJsonEncoding(elem, parentKey);
            if (clean) {
                [result addObject:clean];
            } else if (parentKey != nil) {
                printErrf(@"Invalid JSON value type in array at index %d "
                          @"under key '%@': %@ (%@)",
                          i, parentKey, elem, [elem class]);
            } else {
                printErrf(
                    @"Invalid JSON value type in array at index %d: %@ (%@)", i,
                    elem, [elem class]);
            }
        }
        return result;
    } else if ([value isKindOfClass:[NSString class]] ||
               [value isKindOfClass:[NSNull class]]) {
        return value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        double unwrapped = [number doubleValue];
        if (isnan(unwrapped) || isinf(unwrapped)) {
            return unsupported_type;
        }
        return value;
    } else if ([value isKindOfClass:[NSDate class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          formatter = [[NSDateFormatter alloc] init];
          formatter.locale =
              [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
          formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
          formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        });
        return [formatter stringFromDate:(NSDate *)value];
    } else if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSData class]]) {
        return [(NSData *)value base64EncodedStringWithOptions:0];
    } else {
        return unsupported_type;
    }
}

static NSDictionary *sanitizeDictionaryForJsonEncoding(NSDictionary *data) {
    return sanitizeValueForJsonEncoding(data, nil);
}

NSString *serializeJsonDictionarySafe(NSDictionary *any, bool prettyPrint) {
    if (any == nil) {
        NSCAssert(false, @"Cannot serialize nil as JSON");
        return JSON_NULL;
    }
    any = sanitizeDictionaryForJsonEncoding(any);
    if (any == nil) {
        NSCAssert(false, @"Sanitized JSON dictionary is nil");
        return JSON_NULL;
    }
    NSCAssert([NSJSONSerialization isValidJSONObject:any],
              @"Sanitized JSON dictionary is not a valid JSON object");
    @try {
        NSError *error;
        NSJSONWritingOptions options =
            prettyPrint ? NSJSONWritingPrettyPrinted : 0;
        NSData *serialized = [NSJSONSerialization dataWithJSONObject:any
                                                             options:options
                                                               error:&error];
        if (!serialized) {
            printErrf(@"Failed to serialize JSON: %@", error);
            return nil;
        }
        return [[NSString alloc] initWithData:serialized
                                     encoding:NSUTF8StringEncoding];
    } @catch (NSException *exception) {
        if ([exception.name isEqualToString:NSInvalidArgumentException]) {
            printErrf(@"Exception during JSON serialization: %@: %@", exception,
                      [any class]);
        } else {
            printErrf(@"Exception during JSON serialization: %@", exception);
        }
        return nil;
    }
}

/*
// Dictionary with invalid values to test sanitization before serialization.
any = @{
    @"validString" : @"Hello",
    @"validNumber" : @123,
    @"invalidDate" : [NSDate date],
    @"invalidURL" : [NSURL URLWithString:@"https://apple.com"],
    @"invalidSet" : [NSSet setWithObjects:@"a", @"b", nil],
    @"nestedDict" : @{@42 : @"badKey", @"validNestedKey" :
    @"nestedValue"},
    @123 : @"badKeyAtRoot",
    @"binaryData" :
        [@"Hello, base64!" dataUsingEncoding:NSUTF8StringEncoding],
    @"invalidArray" : @[
        @"okay", [@"Hello, base64!"
        dataUsingEncoding:NSUTF8StringEncoding]
    ],
};
*/

bool appForPID(int pid, void (^block)(NSRunningApplication *)) {
    if (pid <= 0) {
        return false;
    }
    NSRunningApplication *process =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (process == nil) {
        return false;
    }
    block(process);
    return true;
}

static NSString *guessImageMimeTypeFromData(NSData *data) {
    if (!data)
        return nil;
    CGImageSourceRef src =
        CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src)
        return nil;
    CFStringRef uti = CGImageSourceGetType(src);
    CFRelease(src);
    if (!uti)
        return nil;
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
    UTType *type = [UTType typeWithIdentifier:(__bridge NSString *)uti];
    return type.preferredMIMEType;
#else
    CFStringRef mime =
        UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType);
    if (!mime)
        return nil;
    NSString *mimeType = (__bridge_transfer NSString *)mime;
    return mimeType;
#endif
}

void makePayloadHumanReadable(NSMutableDictionary *dict) {
    for (NSString *key in [dict allKeys]) {
        id value = dict[key];
        if ([value isKindOfClass:[NSData class]]) {
            NSString *mimeType = guessImageMimeTypeFromData(value);
            dict[key] = [NSString
                stringWithFormat:@"<%@%@%lu bytes...>", mimeType ?: @"",
                                 mimeType ? @" " : @"",
                                 (unsigned long)[value length]];
        }
    }
}
