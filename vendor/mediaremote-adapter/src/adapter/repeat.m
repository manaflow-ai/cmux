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

static NSArray<NSNumber *> *acceptedModes;

__attribute__((constructor)) static void init() {
    acceptedModes = @[
        @(kMRARepeatDisabled),
        @(kMRARepeatTrack),
        @(kMRARepeatPlaylist),
    ];
}

static bool isModeAccepted(int mode) {
    return [acceptedModes containsObject:@(mode)];
}

void adapter_repeat(MRARepeatMode mode) {

    if (!isModeAccepted((int)mode)) {
        failf(@"Invalid repeat mode: %d", (int)mode);
    }

    g_mediaRemote.setRepeatMode((int)mode);

    waitForCommandCompletion();
}

static inline int repeat_0_mode() {
    return getEnvFuncParamIntSafe(@"adapter_repeat", 0, @"mode");
}

void adapter_repeat_env() { adapter_repeat((MRARepeatMode)repeat_0_mode()); }
