// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#ifndef MEDIAREMOTEADAPTER_UTILITY_HELPERS_H
#define MEDIAREMOTEADAPTER_UTILITY_HELPERS_H

#include <stdarg.h>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

void printOut(NSString *message);
void printOutUnique(NSString *message);
void printErr(NSString *message);
void printErrf(NSString *format, ...);

void fail(NSString *message);
void failf(NSString *format, ...);

NSString *formatError(NSError *error);
NSString *serializeJsonDictionarySafe(NSDictionary *any, bool prettyPrint);

bool appForPID(int pid, void (^block)(NSRunningApplication *));

void makePayloadHumanReadable(NSMutableDictionary *dict);

#endif // MEDIAREMOTEADAPTER_UTILITY_HELPERS_H
