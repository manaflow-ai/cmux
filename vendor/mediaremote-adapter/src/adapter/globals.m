// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#import "globals.h"

#import "utility/helpers.h"

MediaRemote *g_mediaRemote = NULL;
dispatch_queue_t g_serialdispatchQueue;

__attribute__((constructor)) static void initGlobals() {
    g_mediaRemote = [[MediaRemote alloc] init];
    if (!g_mediaRemote) {
        fail(@"Failed to initialize MediaRemote Framework");
        return;
    }
    g_serialdispatchQueue = dispatch_queue_create(
        "mediaremote-adapter.serial-dispatch-queue", DISPATCH_QUEUE_SERIAL);
}
