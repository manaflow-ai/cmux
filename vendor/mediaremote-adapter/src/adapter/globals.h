// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#ifndef MEDIAREMOTEADAPTER_ADAPTER_GLOBALS_H
#define MEDIAREMOTEADAPTER_ADAPTER_GLOBALS_H

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

#import "private/MediaRemote.h"

extern MediaRemote* g_mediaRemote;
extern dispatch_queue_t g_serialdispatchQueue;

#endif // MEDIAREMOTEADAPTER_ADAPTER_GLOBALS_H
