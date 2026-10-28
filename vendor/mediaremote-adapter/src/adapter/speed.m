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

void adapter_speed(int speed) {

    if (speed < 0) {
        failf(@"Negative values are not allowed: %d", speed);
    }

    g_mediaRemote.setPlaybackSpeed(speed);

    waitForCommandCompletion();
}

static inline int speed_0_speed() {
    return getEnvFuncParamIntSafe(@"adapter_speed", 0, @"speed");
}

void adapter_speed_env() { adapter_speed(speed_0_speed()); }
