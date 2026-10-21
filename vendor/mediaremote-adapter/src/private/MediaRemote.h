// clang-format off

#ifndef MEDIAREMOTE_PRIVATE_H_
#define MEDIAREMOTE_PRIVATE_H_

#include <Foundation/Foundation.h>

#pragma mark Notifications

extern NSString *kMRMediaRemoteNowPlayingInfoDidChangeNotification;
extern NSString *kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification;
extern NSString *kMRMediaRemotePickableRoutesDidChangeNotification;
extern NSString *kMRMediaRemoteNowPlayingApplicationDidChangeNotification;
extern NSString *kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification;
extern NSString *kMRMediaRemoteRouteStatusDidChangeNotification;

#pragma mark Keys

extern NSString *kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey;
extern NSString *kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey;
extern NSString *kMRMediaRemoteNowPlayingInfoAlbum;
extern NSString *kMRMediaRemoteNowPlayingInfoArtist;
extern NSString *kMRMediaRemoteNowPlayingInfoArtworkData;
extern NSString *kMRMediaRemoteNowPlayingInfoArtworkMIMEType;
extern NSString *kMRMediaRemoteNowPlayingInfoChapterNumber;
extern NSString *kMRMediaRemoteNowPlayingInfoComposer;
extern NSString *kMRMediaRemoteNowPlayingInfoDuration;
extern NSString *kMRMediaRemoteNowPlayingInfoElapsedTime;
extern NSString *kMRMediaRemoteNowPlayingInfoGenre;
extern NSString *kMRMediaRemoteNowPlayingInfoIsAdvertisement;
extern NSString *kMRMediaRemoteNowPlayingInfoIsBanned;
extern NSString *kMRMediaRemoteNowPlayingInfoIsInWishList;
extern NSString *kMRMediaRemoteNowPlayingInfoIsLiked;
extern NSString *kMRMediaRemoteNowPlayingInfoIsMusicApp;
extern NSString *kMRMediaRemoteNowPlayingInfoPlaybackRate;
extern NSString *kMRMediaRemoteNowPlayingInfoProhibitsSkip;
extern NSString *kMRMediaRemoteNowPlayingInfoQueueIndex;
extern NSString *kMRMediaRemoteNowPlayingInfoRadioStationIdentifier;
extern NSString *kMRMediaRemoteNowPlayingInfoRepeatMode;
extern NSString *kMRMediaRemoteNowPlayingInfoShuffleMode;
extern NSString *kMRMediaRemoteNowPlayingInfoStartTime;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsFastForward15Seconds;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsIsBanned;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsIsLiked;
extern NSString *kMRMediaRemoteNowPlayingInfoSupportsRewind15Seconds;
extern NSString *kMRMediaRemoteNowPlayingInfoTimestamp;
extern NSString *kMRMediaRemoteNowPlayingInfoTitle;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalChapterCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalDiscCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalQueueCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTotalTrackCount;
extern NSString *kMRMediaRemoteNowPlayingInfoTrackNumber;
extern NSString *kMRMediaRemoteNowPlayingInfoUniqueIdentifier;
extern NSString *kMRMediaRemoteNowPlayingInfoContentItemIdentifier;
extern NSString *kMRMediaRemoteNowPlayingInfoRadioStationHash;
extern NSString *kMRMediaRemoteNowPlayingInfoMediaType;
extern NSString *kMRMediaRemoteNowPlayingInfoServiceIdentifier;
extern NSString *kMRMediaRemoteOptionMediaType;
extern NSString *kMRMediaRemoteOptionSourceID;
extern NSString *kMRMediaRemoteOptionTrackID;
extern NSString *kMRMediaRemoteOptionStationID;
extern NSString *kMRMediaRemoteOptionStationHash;
extern NSString *kMRMediaRemoteRouteDescriptionUserInfoKey;
extern NSString *kMRMediaRemoteRouteStatusUserInfoKey;

#pragma mark API

typedef enum {
    /*
     * Use nil for userInfo.
     */
    kMRPlay = 0,
    kMRPause = 1,
    kMRTogglePlayPause = 2,
    kMRStop = 3,
    kMRNextTrack = 4,
    kMRPreviousTrack = 5,
    kMRToggleShuffle = 6,
    kMRToggleRepeat = 7,
    kMRStartForwardSeek = 8,
    kMREndForwardSeek = 9,
    kMRStartBackwardSeek = 10,
    kMREndBackwardSeek = 11,
    kMRGoBackFifteenSeconds = 12,
    kMRSkipFifteenSeconds = 13,

    /*
     * Use a NSDictionary for userInfo, which contains three keys:
     * kMRMediaRemoteOptionTrackID
     * kMRMediaRemoteOptionStationID
     * kMRMediaRemoteOptionStationHash
     */
    kMRLikeTrack = 0x6A,
    kMRBanTrack = 0x6B,
    kMRAddTrackToWishList = 0x6C,
    kMRRemoveTrackFromWishList = 0x6D
} MRCommand;

extern CFStringRef MRMediaRemoteSendCommand;
typedef bool (*MRMediaRemoteSendCommand_t)(MRCommand command, id userInfo);

extern CFStringRef MRMediaRemoteSetPlaybackSpeed;
extern CFStringRef MRMediaRemoteSetElapsedTime;
extern CFStringRef MRMediaRemoteSetShuffleMode;
extern CFStringRef MRMediaRemoteSetRepeatMode;
typedef void (*MRMediaRemoteSetPlaybackSpeed_t)(int speed);
typedef void (*MRMediaRemoteSetElapsedTime_t)(double elapsedTime);
typedef void (*MRMediaRemoteSetShuffleMode_t)(int mode);
typedef void (*MRMediaRemoteSetRepeatMode_t)(int mode);

extern CFStringRef MRMediaRemoteRegisterForNowPlayingNotifications;
extern CFStringRef MRMediaRemoteUnregisterForNowPlayingNotifications;
extern CFStringRef MRMediaRemoteGetNowPlayingApplicationPID;
extern CFStringRef MRMediaRemoteGetNowPlayingClient;
extern CFStringRef MRMediaRemoteGetNowPlayingInfo;
extern CFStringRef MRMediaRemoteGetNowPlayingApplicationIsPlaying;

typedef void (*MRMediaRemoteRegisterForNowPlayingNotifications_t)(dispatch_queue_t queue);
typedef void (*MRMediaRemoteUnregisterForNowPlayingNotifications_t)();

typedef void (^MRMediaRemoteGetNowPlayingInfoCompletion_t)(NSDictionary *information);
typedef void (^MRMediaRemoteGetNowPlayingApplicationPIDCompletion_t)(int PID);
typedef void (^MRMediaRemoteGetNowPlayingClientCompletion_t)(id clientObj);
typedef void (^MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion_t)(bool isPlaying);

typedef void (*MRMediaRemoteGetNowPlayingApplicationPID_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationPIDCompletion_t completion);
typedef void (*MRMediaRemoteGetNowPlayingClient_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingClientCompletion_t completion);
typedef void (*MRMediaRemoteGetNowPlayingInfo_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion_t completion);
typedef void (*MRMediaRemoteGetNowPlayingApplicationIsPlaying_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion_t completion);

#pragma mark Miscellaneous

extern NSString *kMRNowPlayingClientUserInfoKey;

// Accessed with the kMRNowPlayingClientUserInfoKey
// on the userInfo dictionary of an NSNotification.
@interface MRClient : NSObject {}
-(NSString *)parentApplicationBundleIdentifier;
-(NSString *)bundleIdentifier;
-(NSString *)displayName;
@end

@interface MediaRemote : NSObject
// Commands
@property(readonly) MRMediaRemoteSendCommand_t sendCommand;
// Other controls
@property(readonly) MRMediaRemoteSetPlaybackSpeed_t setPlaybackSpeed;
@property(readonly) MRMediaRemoteSetElapsedTime_t setElapsedTime;
@property(readonly) MRMediaRemoteSetShuffleMode_t setShuffleMode;
@property(readonly) MRMediaRemoteSetRepeatMode_t setRepeatMode;
// Observers
@property(readonly) MRMediaRemoteRegisterForNowPlayingNotifications_t registerForNowPlayingNotifications;
@property(readonly) MRMediaRemoteUnregisterForNowPlayingNotifications_t unregisterForNowPlayingNotifications;
// Metadata
@property(readonly) MRMediaRemoteGetNowPlayingApplicationPID_t getNowPlayingApplicationPID;
@property(readonly) MRMediaRemoteGetNowPlayingClient_t getNowPlayingClient;
@property(readonly) MRMediaRemoteGetNowPlayingInfo_t getNowPlayingInfo;
@property(readonly) MRMediaRemoteGetNowPlayingApplicationIsPlaying_t getNowPlayingApplicationIsPlaying;
// Constructor
-(id)init;
@end

#endif /* MEDIAREMOTE_PRIVATE_H_ */
