// Copyright (c) 2025 Alexander5015
// This file is licensed under the BSD 3-Clause License.

#import <Foundation/Foundation.h>
#include <signal.h>

#import "MediaRemoteAdapter.h"
#import "adapter/get.h"
#import "test/NowPlayingTest.h"
#import "utility/helpers.h"

static NSTask *nowPlayingClientHelperTask = nil;
static NSFileHandle *helperInput = nil;
static NSFileHandle *helperOutput = nil;

void cleanup_helper() {
    if (nowPlayingClientHelperTask && helperInput && helperOutput) {
        @try {
            [helperInput writeData:[@"cleanup\n"
                                       dataUsingEncoding:NSUTF8StringEncoding]];
            [helperInput closeFile];
        } @catch (NSException *exception) {
        }

        // Graceful shutdown with timeout
        NSTimeInterval timeout = 2.0;
        NSDate *cleanupDeadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while (nowPlayingClientHelperTask.isRunning &&
               [cleanupDeadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.1];
        }

        if (nowPlayingClientHelperTask.isRunning) {
            @try {
                [nowPlayingClientHelperTask terminate];
            } @catch (NSException *exception) {
            }

            NSDate *terminationDeadline =
                [NSDate dateWithTimeIntervalSinceNow:1.0];
            while (nowPlayingClientHelperTask.isRunning &&
                   [terminationDeadline timeIntervalSinceNow] > 0) {
                [NSThread sleepForTimeInterval:0.1];
            }
        }

        if (nowPlayingClientHelperTask.isRunning) {
            // Force kill as last resort
            kill(nowPlayingClientHelperTask.processIdentifier, SIGKILL);
        }

        @try {
            if (helperOutput.readabilityHandler) {
                helperOutput.readabilityHandler = nil;
            }
            [helperOutput closeFile];
        } @catch (__unused NSException *exception) {
        }

        @
        try {
            [nowPlayingClientHelperTask waitUntilExit];
        } @catch (__unused NSException *exception) {
        }
    } else if (nowPlayingClientHelperTask) {
        @try {
            [nowPlayingClientHelperTask terminate];
            [nowPlayingClientHelperTask waitUntilExit];
        } @catch (__unused NSException *exception) {
        }
    }
    nowPlayingClientHelperTask = nil;
    helperInput = nil;
    helperOutput = nil;
}

void cleanup_and_exit() {
    cleanup_helper();
    exit(1);
}

void handleSignal(int signal) {
    if (signal == SIGINT || signal == SIGTERM)
        cleanup_and_exit();
}

extern void adapter_test(void) {
    @autoreleasepool {
        signal(SIGINT, handleSignal);
        signal(SIGTERM, handleSignal);
        signal(SIGPIPE, SIG_IGN);

        // If adapterOutput is not null, we know the adapter is working
        // correctly
        NSDictionary *result = internal_get(YES);
        if (result != nil) {
            cleanup_helper();
            exit(0);
        }

        // Instantiate helper to ensure MediaRemote has data
        // We only do this if adapterOutput is null to minimize the impact on
        // other apps using the adapter
        NSString *helperPath =
            NSProcessInfo.processInfo
                .environment[@"MEDIAREMOTEADAPTER_TEST_CLIENT_PATH"];
        if (helperPath.length == 0) {
            printErrf(@"Test client path is missing");
            cleanup_helper();
            exit(1);
        }

        // Set up pipes for communication with the helper process
        NSPipe *inputPipe = [NSPipe pipe];
        NSPipe *outputPipe = [NSPipe pipe];

        nowPlayingClientHelperTask = [[NSTask alloc] init];
        nowPlayingClientHelperTask.launchPath = helperPath;
        nowPlayingClientHelperTask.standardInput = inputPipe;
        nowPlayingClientHelperTask.standardOutput = outputPipe;

        @try {
            [nowPlayingClientHelperTask launch];
        } @catch (NSException *exception) {
            printErrf(
                @"Exeption while trying to launch test client task: %@: %@",
                exception.name, exception.reason);
            cleanup_helper();
            exit(2);
        }

        helperInput = inputPipe.fileHandleForWriting;
        helperOutput = outputPipe.fileHandleForReading;

        dispatch_semaphore_t setupSem = dispatch_semaphore_create(0);
        NSMutableString *lineBuffer = [[NSMutableString alloc] init];
        helperOutput.readabilityHandler = ^(NSFileHandle *fh) {
          @autoreleasepool {
              NSData *chunk = [fh availableData];
              if (chunk.length == 0) {
                  fh.readabilityHandler = nil;
                  return;
              }

              // Validate UTF-8 encoding with graceful degradation
              NSString *chunkStr =
                  [[NSString alloc] initWithData:chunk
                                        encoding:NSUTF8StringEncoding];
              if (!chunkStr) {
                  return;
              }

              [lineBuffer appendString:chunkStr];

              NSUInteger bufferLength = [lineBuffer length];
              NSUInteger searchStart = 0;

              while (searchStart < bufferLength) {
                  NSRange remainingRange =
                      NSMakeRange(searchStart, bufferLength - searchStart);
                  NSRange nlRange = [lineBuffer rangeOfString:@"\n"
                                                      options:0
                                                        range:remainingRange];

                  if (nlRange.location == NSNotFound) {
                      break;
                  }

                  NSUInteger lineLength = nlRange.location - searchStart;
                  NSString *line = [lineBuffer
                      substringWithRange:NSMakeRange(searchStart, lineLength)];

                  if ([line isEqualToString:@"setup_done"]) {
                      fh.readabilityHandler = nil;
                      dispatch_semaphore_signal(setupSem);
                      return;
                  }

                  searchStart = nlRange.location + nlRange.length;
              }
              if (searchStart > 0) {
                  [lineBuffer
                      deleteCharactersInRange:NSMakeRange(0, searchStart)];
              }
          }
        };
        // Wait for setup_done or timeout
        NSTimeInterval setupTimeout = 3.0;
        dispatch_time_t timeout = dispatch_time(
            DISPATCH_TIME_NOW, (int64_t)(setupTimeout * NSEC_PER_SEC));
        long result_wait = dispatch_semaphore_wait(setupSem, timeout);

        if (helperOutput.readabilityHandler) {
            helperOutput.readabilityHandler = nil;
        }

        if (result_wait != 0) {
            printErrf(@"The test client did not signal setup_done within %.1fs",
                      setupTimeout);
            cleanup_helper();
            exit(3);
        }

        // Small delay to ensure new data is available, for some reason the
        // first call to adapter_get slows down MediaRemote?
        [NSThread sleepForTimeInterval:0.01];

        result = internal_get(YES);
        if (result != nil) {
            cleanup_helper();
            exit(0);
        }

        cleanup_helper();
        exit(4);
    }
}
