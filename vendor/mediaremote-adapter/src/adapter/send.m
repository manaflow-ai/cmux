// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#include "private/MediaRemote.h"
#include <limits.h>

#import <Foundation/Foundation.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/now_playing.h"
#import "utility/helpers.h"

static NSArray<NSNumber *> *acceptedCommands;

__attribute__((constructor)) static void init() {
    acceptedCommands = @[
        @(kMRAPlay),
        @(kMRAPause),
        @(kMRATogglePlayPause),
        @(kMRAStop),
        @(kMRANextTrack),
        @(kMRAPreviousTrack),
        @(kMRAToggleShuffle),
        @(kMRAToggleRepeat),
        @(kMRAStartForwardSeek),
        @(kMRAEndForwardSeek),
        @(kMRAStartBackwardSeek),
        @(kMRAEndBackwardSeek),
        @(kMRAGoBackFifteenSeconds),
        @(kMRASkipFifteenSeconds),
    ];
    // TODO like/unlike tracks by reading now playing information first,
    // getting the track ID, station ID and station hash
    // and then sending the respective MRCommand.
    // does "ban" mean "remove like" here?
}

static MRCommand findCommand(int command, bool *found) {
    if ([acceptedCommands containsObject:@(command)]) {
        *found = true;
        return (MRCommand)command;
    }
    *found = false;
    return (MRCommand)0;
}

void adapter_send(MRACommand command) {

    bool ok = false;
    MRCommand commandValue = findCommand((int)command, &ok);
    if (!ok) {
        failf(@"Invalid command: %d", command);
    }

    bool result = g_mediaRemote.sendCommand(commandValue, nil);
    if (!result) {
        failf(@"Failed to send command %d", command);
    }

    waitForCommandCompletion();
}

static inline int send_0_command() {
    return getEnvFuncParamIntSafe(@"adapter_send", 0, @"command");
}

void adapter_send_env() { adapter_send((MRACommand)send_0_command()); }
