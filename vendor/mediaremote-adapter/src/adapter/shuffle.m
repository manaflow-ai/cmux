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
        @(kMRAShuffleDisabled),
        @(kMRAShuffleAlbums),
        @(kMRAShuffleTracks),
    ];
}

static bool isModeAccepted(int mode) {
    return [acceptedModes containsObject:@(mode)];
}

void adapter_shuffle(MRAShuffleMode mode) {

    if (!isModeAccepted((int)mode)) {
        failf(@"Invalid shuffle mode: %d", (int)mode);
    }

    g_mediaRemote.setShuffleMode((int)mode);

    waitForCommandCompletion();
}

static inline int shuffle_0_mode() {
    return getEnvFuncParamIntSafe(@"adapter_shuffle", 0, @"mode");
}

void adapter_shuffle_env() {
    adapter_shuffle((MRAShuffleMode)shuffle_0_mode());
}
