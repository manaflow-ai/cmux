// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#import "now_playing.h"

#import "MediaRemoteAdapter.h"
#import "adapter/globals.h"
#import "adapter/keys.h"
#import "private/MediaRemote.h"

#define WAIT_TIMEOUT_MILLIS 2000

void waitForCommandCompletion() {
    id semaphore = dispatch_semaphore_create(0);

    g_mediaRemote.getNowPlayingApplicationPID(
        g_serialdispatchQueue, ^(int pid) {
          dispatch_semaphore_signal(semaphore);
        });

    dispatch_time_t timeout =
        dispatch_time(DISPATCH_TIME_NOW, WAIT_TIMEOUT_MILLIS * NSEC_PER_MSEC);
    dispatch_semaphore_wait(semaphore, timeout);
}

NSNumber *getElapsedTimeNow(NSDictionary *information) {
    id elapsed = information[kMRMediaRemoteNowPlayingInfoElapsedTime];
    if (![elapsed isKindOfClass:[NSNumber class]]) {
        return nil;
    }

    id timestamp = information[kMRMediaRemoteNowPlayingInfoTimestamp];
    if (![timestamp isKindOfClass:[NSDate class]]) {
        return elapsed;
    }

    NSTimeInterval timestampEpoch = [(NSDate *)timestamp timeIntervalSince1970];
    NSTimeInterval currentEpoch = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval timeDiff = currentEpoch - timestampEpoch;

    double playbackRate = 0;
    id playbackRateVal = information[kMRMediaRemoteNowPlayingInfoPlaybackRate];
    if ([playbackRateVal isKindOfClass:[NSNumber class]]) {
        playbackRate = [(NSNumber *)playbackRateVal doubleValue];
    }

    double realElapsed = [(NSNumber *)elapsed doubleValue];
    if (playbackRate >= 0) {
        realElapsed += timeDiff * playbackRate;
    }

    return @(realElapsed);
}

NSMutableDictionary *convertNowPlayingInformation(NSDictionary *information,
                                                  bool convertMicros,
                                                  bool calculateNow,
                                                  bool withoutArtwork) {
    NSMutableDictionary *data = [NSMutableDictionary dictionary];

    void (^setKey)(id, id) = ^(id key, id fromKey) {
      id value = nil;
      if (information != nil) {
          id result = information[fromKey];
          if (result != nil) {
              value = result;
          }
      }
      if (value != nil) {
          [data setObject:value forKey:key];
      }
    };

    void (^setValue)(id key, id (^)(void)) = ^(id key, id (^evaluate)(void)) {
      id value = nil;
      if (information != nil) {
          value = evaluate();
      }
      if (value != nil) {
          [data setObject:value forKey:key];
      }
    };

    setKey(kMRATitle, kMRMediaRemoteNowPlayingInfoTitle);
    setKey(kMRAArtist, kMRMediaRemoteNowPlayingInfoArtist);
    setKey(kMRAAlbum, kMRMediaRemoteNowPlayingInfoAlbum);
    if (!withoutArtwork) {
        setKey(kMRAArtworkMimeType,
               kMRMediaRemoteNowPlayingInfoArtworkMIMEType);
        setKey(kMRAArtworkData, kMRMediaRemoteNowPlayingInfoArtworkData);
    }

    if (!convertMicros) {
        setKey(kMRADuration, kMRMediaRemoteNowPlayingInfoDuration);
        setKey(kMRAElapsedTime, kMRMediaRemoteNowPlayingInfoElapsedTime);
        setKey(kMRATimestamp, kMRMediaRemoteNowPlayingInfoTimestamp);
        if (calculateNow) {
            // This key is added and does not replace the original because it
            // is just a rough estimation, meant to be used for convenience.
            setValue(kMRAElapsedTimeNow, ^id {
              id elapsedTime =
                  information[kMRMediaRemoteNowPlayingInfoElapsedTime];
              id nowValue = getElapsedTimeNow(information);
              if (nowValue != nil) {
                  elapsedTime = nowValue;
              }
              return elapsedTime;
            });
        }
    } else {
        // These keys replace their original counterparts because semantics
        // don't change and no accuracy is lost, merely the time unit changes.
        setValue(kMRADurationMicros, ^id {
          id duration = information[kMRMediaRemoteNowPlayingInfoDuration];
          if (duration != nil && [duration isKindOfClass:[NSNumber class]]) {
              NSTimeInterval durationMicros =
                  [duration doubleValue] * 1000 * 1000;
              return @(floor(durationMicros));
          }
          return nil;
        });
        setValue(kMRAElapsedTimeMicros, ^id {
          id elapsedTime = information[kMRMediaRemoteNowPlayingInfoElapsedTime];
          if (elapsedTime != nil &&
              [elapsedTime isKindOfClass:[NSNumber class]]) {
              NSTimeInterval elapsedTimeMicros =
                  [elapsedTime doubleValue] * 1000 * 1000;
              return @(floor(elapsedTimeMicros));
          }
          return nil;
        });
        if (calculateNow) {
            // This key is added and does not replace the original because it
            // is just a rough estimation, meant to be used for convenience.
            setValue(kMRAElapsedTimeNowMicros, ^id {
              id elapsedTime =
                  information[kMRMediaRemoteNowPlayingInfoElapsedTime];
              if (calculateNow) {
                  elapsedTime = getElapsedTimeNow(information);
              }
              if (elapsedTime != nil &&
                  [elapsedTime isKindOfClass:[NSNumber class]]) {
                  NSTimeInterval elapsedTimeMicros =
                      [elapsedTime doubleValue] * 1000 * 1000;
                  return @(floor(elapsedTimeMicros));
              }
              return nil;
            });
        }
        setValue(kMRATimestampEpochMicros, ^id {
          id timestamp = information[kMRMediaRemoteNowPlayingInfoTimestamp];
          if (timestamp != nil && [timestamp isKindOfClass:[NSDate class]]) {
              NSTimeInterval timestampEpoch = [timestamp timeIntervalSince1970];
              NSTimeInterval timestampEpochMicro = timestampEpoch * 1000 * 1000;
              return @(floor(timestampEpochMicro));
          }
          return nil;
        });
    }

    // Some of the following keys might fail due to not being convertible
    // to JSON automatically. This is difficult to test because most media
    // players do not even set these keys and the data types are not documented
    // anywhere. Still, JSON serialization of the resulting dictionary deletes
    // any invalid keys, converts or deletes invalid values and prints error
    // messages whenever any dictionary entry has been removed. Users should
    // report whenever they encounter such an error with these keys.

    // clang-format off
    setKey(kMRAChapterNumber, kMRMediaRemoteNowPlayingInfoChapterNumber);
    setKey(kMRAComposer, kMRMediaRemoteNowPlayingInfoComposer);
    setKey(kMRAGenre, kMRMediaRemoteNowPlayingInfoGenre);
    setKey(kMRAIsAdvertisement, kMRMediaRemoteNowPlayingInfoIsAdvertisement);
    setKey(kMRAIsBanned, kMRMediaRemoteNowPlayingInfoIsBanned);
    setKey(kMRAIsInWishList, kMRMediaRemoteNowPlayingInfoIsInWishList);
    setKey(kMRAIsLiked, kMRMediaRemoteNowPlayingInfoIsLiked);
    setKey(kMRAIsMusicApp, kMRMediaRemoteNowPlayingInfoIsMusicApp);
    setKey(kMRAPlaybackRate, kMRMediaRemoteNowPlayingInfoPlaybackRate);
    setKey(kMRAProhibitsSkip, kMRMediaRemoteNowPlayingInfoProhibitsSkip);
    setKey(kMRAQueueIndex, kMRMediaRemoteNowPlayingInfoQueueIndex);
    setKey(kMRARadioStationIdentifier, kMRMediaRemoteNowPlayingInfoRadioStationIdentifier);
    setKey(kMRARepeatMode, kMRMediaRemoteNowPlayingInfoRepeatMode);
    setKey(kMRAShuffleMode, kMRMediaRemoteNowPlayingInfoShuffleMode);
    setKey(kMRAStartTime, kMRMediaRemoteNowPlayingInfoStartTime);
    setKey(kMRASupportsFastForward15Seconds, kMRMediaRemoteNowPlayingInfoSupportsFastForward15Seconds);
    setKey(kMRASupportsIsBanned, kMRMediaRemoteNowPlayingInfoSupportsIsBanned);
    setKey(kMRASupportsIsLiked, kMRMediaRemoteNowPlayingInfoSupportsIsLiked);
    setKey(kMRASupportsRewind15Seconds, kMRMediaRemoteNowPlayingInfoSupportsRewind15Seconds);
    setKey(kMRATotalChapterCount, kMRMediaRemoteNowPlayingInfoTotalChapterCount);
    setKey(kMRATotalDiscCount, kMRMediaRemoteNowPlayingInfoTotalDiscCount);
    setKey(kMRATotalQueueCount, kMRMediaRemoteNowPlayingInfoTotalQueueCount);
    setKey(kMRATotalTrackCount, kMRMediaRemoteNowPlayingInfoTotalTrackCount);
    setKey(kMRATrackNumber, kMRMediaRemoteNowPlayingInfoTrackNumber);
    setKey(kMRAUniqueIdentifier, kMRMediaRemoteNowPlayingInfoUniqueIdentifier);
    setKey(kMRAContentItemIdentifier, kMRMediaRemoteNowPlayingInfoContentItemIdentifier);
    setKey(kMRARadioStationHash, kMRMediaRemoteNowPlayingInfoRadioStationHash);
    setKey(kMRAMediaType, kMRMediaRemoteNowPlayingInfoMediaType);
    // clang-format on

    return data;
}
