// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#import "keys.h"

#import "MediaRemoteAdapter.h"

NSString *kMRAProcessIdentifier = @"processIdentifier";
NSString *kMRABundleIdentifier = @"bundleIdentifier";
NSString *kMRAParentApplicationBundleIdentifier =
    @"parentApplicationBundleIdentifier";
NSString *kMRAPlaying = @"playing";

NSString *kMRADurationMicros = @"durationMicros";
NSString *kMRAElapsedTimeMicros = @"elapsedTimeMicros";
NSString *kMRATimestampEpochMicros = @"timestampEpochMicros";

NSString *kMRAElapsedTimeNow = @"elapsedTimeNow";
NSString *kMRAElapsedTimeNowMicros = @"elapsedTimeNowMicros";

NSString *kMRATitle = @"title";
NSString *kMRAArtist = @"artist";
NSString *kMRAAlbum = @"album";
NSString *kMRADuration = @"duration";
NSString *kMRAElapsedTime = @"elapsedTime";
NSString *kMRATimestamp = @"timestamp";
NSString *kMRAArtworkMimeType = @"artworkMimeType";
NSString *kMRAArtworkData = @"artworkData";

NSString *kMRAChapterNumber = @"chapterNumber";
NSString *kMRAComposer = @"composer";
NSString *kMRAGenre = @"genre";
NSString *kMRAIsAdvertisement = @"isAdvertisement";
NSString *kMRAIsBanned = @"isBanned";
NSString *kMRAIsInWishList = @"isInWishList";
NSString *kMRAIsLiked = @"isLiked";
NSString *kMRAIsMusicApp = @"isMusicApp";
NSString *kMRAPlaybackRate = @"playbackRate";
NSString *kMRAProhibitsSkip = @"prohibitsSkip";
NSString *kMRAQueueIndex = @"queueIndex";
NSString *kMRARadioStationIdentifier = @"radioStationIdentifier";
NSString *kMRARepeatMode = @"repeatMode";
NSString *kMRAShuffleMode = @"shuffleMode";
NSString *kMRAStartTime = @"startTime";
NSString *kMRASupportsFastForward15Seconds = @"supportsFastForward15Seconds";
NSString *kMRASupportsIsBanned = @"supportsIsBanned";
NSString *kMRASupportsIsLiked = @"supportsIsLiked";
NSString *kMRASupportsRewind15Seconds = @"supportsRewind15Seconds";
NSString *kMRATotalChapterCount = @"totalChapterCount";
NSString *kMRATotalDiscCount = @"totalDiscCount";
NSString *kMRATotalQueueCount = @"totalQueueCount";
NSString *kMRATotalTrackCount = @"totalTrackCount";
NSString *kMRATrackNumber = @"trackNumber";
NSString *kMRAUniqueIdentifier = @"uniqueIdentifier";
NSString *kMRAContentItemIdentifier = @"contentItemIdentifier";
NSString *kMRARadioStationHash = @"radioStationHash";
NSString *kMRAMediaType = @"mediaType";

NSArray<NSString *> *mandatoryPayloadKeys(bool excludeTitle) {
    NSMutableArray<NSString *> *keys =
        [NSMutableArray arrayWithArray:@[ kMRAProcessIdentifier, kMRAPlaying ]];
    if (!excludeTitle) {
        [keys addObject:kMRATitle];
    }
    return keys;
}

bool allMandatoryPayloadKeysSet(NSDictionary *data, bool allowMissingTitle) {
    NSArray<NSString *> *keys = mandatoryPayloadKeys(allowMissingTitle);
    for (NSString *key in keys) {
        if (data[key] == nil || data[key] == [NSNull null]) {
            return false;
        }
        id value = data[key];
        if ([value isKindOfClass:[NSString class]] &&
            [(NSString *)value length] == 0) {
            return false;
        }
    }
    return true;
}

NSArray<NSString *> *identifyingPayloadKeys(void) {
    return @[
        kMRAProcessIdentifier, kMRABundleIdentifier,
        kMRAParentApplicationBundleIdentifier, kMRATitle, kMRAArtist, kMRAAlbum
    ];
}
