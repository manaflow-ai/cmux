// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#ifndef MEDIAREMOTEADAPTER_UTILITY_NOW_PLAYING_H
#define MEDIAREMOTEADAPTER_UTILITY_NOW_PLAYING_H

#import <Foundation/Foundation.h>

// Requests information once so that the process runs long enough for the
// MediaRemote command to actually be sent to the now playing application.
void waitForCommandCompletion();

// Converts raw MediaRemote now playing information to adapter keys.
// Optionally replaces keys with time values with microseconds equivalents.
NSMutableDictionary *convertNowPlayingInformation(NSDictionary *information,
                                                  bool convertMicros,
                                                  bool calculateNow,
                                                  bool withoutArtwork);

#endif // MEDIAREMOTEADAPTER_UTILITY_NOW_PLAYING_H
