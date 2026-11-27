// clang-format off

#include <Foundation/Foundation.h>

#include "MediaRemote.h"

NSString *kMRMediaRemoteNowPlayingInfoDidChangeNotification = @"kMRMediaRemoteNowPlayingInfoDidChangeNotification";
NSString *kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification = @"kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification";
NSString *kMRMediaRemotePickableRoutesDidChangeNotification = @"kMRMediaRemotePickableRoutesDidChangeNotification";
NSString *kMRMediaRemoteNowPlayingApplicationDidChangeNotification = @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification";
NSString *kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification = @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification";

NSString *kMRMediaRemoteRouteStatusDidChangeNotification = @"kMRMediaRemoteRouteStatusDidChangeNotification";
NSString *kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey = @"kMRMediaRemoteNowPlayingApplicationPIDUserInfoKey";
NSString *kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey = @"kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey";
NSString *kMRMediaRemoteNowPlayingInfoAlbum = @"kMRMediaRemoteNowPlayingInfoAlbum";
NSString *kMRMediaRemoteNowPlayingInfoArtist = @"kMRMediaRemoteNowPlayingInfoArtist";
NSString *kMRMediaRemoteNowPlayingInfoArtworkData = @"kMRMediaRemoteNowPlayingInfoArtworkData";
NSString *kMRMediaRemoteNowPlayingInfoArtworkMIMEType = @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType";
NSString *kMRMediaRemoteNowPlayingInfoChapterNumber = @"kMRMediaRemoteNowPlayingInfoChapterNumber";
NSString *kMRMediaRemoteNowPlayingInfoComposer = @"kMRMediaRemoteNowPlayingInfoComposer";
NSString *kMRMediaRemoteNowPlayingInfoDuration = @"kMRMediaRemoteNowPlayingInfoDuration";
NSString *kMRMediaRemoteNowPlayingInfoElapsedTime = @"kMRMediaRemoteNowPlayingInfoElapsedTime";
NSString *kMRMediaRemoteNowPlayingInfoGenre = @"kMRMediaRemoteNowPlayingInfoGenre";
NSString *kMRMediaRemoteNowPlayingInfoIsAdvertisement = @"kMRMediaRemoteNowPlayingInfoIsAdvertisement";
NSString *kMRMediaRemoteNowPlayingInfoIsBanned = @"kMRMediaRemoteNowPlayingInfoIsBanned";
NSString *kMRMediaRemoteNowPlayingInfoIsInWishList = @"kMRMediaRemoteNowPlayingInfoIsInWishList";
NSString *kMRMediaRemoteNowPlayingInfoIsLiked = @"kMRMediaRemoteNowPlayingInfoIsLiked";
NSString *kMRMediaRemoteNowPlayingInfoIsMusicApp = @"kMRMediaRemoteNowPlayingInfoIsMusicApp";
NSString *kMRMediaRemoteNowPlayingInfoPlaybackRate = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";
NSString *kMRMediaRemoteNowPlayingInfoProhibitsSkip = @"kMRMediaRemoteNowPlayingInfoProhibitsSkip";
NSString *kMRMediaRemoteNowPlayingInfoQueueIndex = @"kMRMediaRemoteNowPlayingInfoQueueIndex";
NSString *kMRMediaRemoteNowPlayingInfoRadioStationIdentifier = @"kMRMediaRemoteNowPlayingInfoRadioStationIdentifier";
NSString *kMRMediaRemoteNowPlayingInfoRepeatMode = @"kMRMediaRemoteNowPlayingInfoRepeatMode";
NSString *kMRMediaRemoteNowPlayingInfoShuffleMode = @"kMRMediaRemoteNowPlayingInfoShuffleMode";
NSString *kMRMediaRemoteNowPlayingInfoStartTime = @"kMRMediaRemoteNowPlayingInfoStartTime";
NSString *kMRMediaRemoteNowPlayingInfoSupportsFastForward15Seconds = @"kMRMediaRemoteNowPlayingInfoSupportsFastForward15Seconds";
NSString *kMRMediaRemoteNowPlayingInfoSupportsIsBanned = @"kMRMediaRemoteNowPlayingInfoSupportsIsBanned";
NSString *kMRMediaRemoteNowPlayingInfoSupportsIsLiked = @"kMRMediaRemoteNowPlayingInfoSupportsIsLiked";
NSString *kMRMediaRemoteNowPlayingInfoSupportsRewind15Seconds = @"kMRMediaRemoteNowPlayingInfoSupportsRewind15Seconds";
NSString *kMRMediaRemoteNowPlayingInfoTimestamp = @"kMRMediaRemoteNowPlayingInfoTimestamp";
NSString *kMRMediaRemoteNowPlayingInfoTitle = @"kMRMediaRemoteNowPlayingInfoTitle";
NSString *kMRMediaRemoteNowPlayingInfoTotalChapterCount = @"kMRMediaRemoteNowPlayingInfoTotalChapterCount";
NSString *kMRMediaRemoteNowPlayingInfoTotalDiscCount = @"kMRMediaRemoteNowPlayingInfoTotalDiscCount";
NSString *kMRMediaRemoteNowPlayingInfoTotalQueueCount = @"kMRMediaRemoteNowPlayingInfoTotalQueueCount";
NSString *kMRMediaRemoteNowPlayingInfoTotalTrackCount = @"kMRMediaRemoteNowPlayingInfoTotalTrackCount";
NSString *kMRMediaRemoteNowPlayingInfoTrackNumber = @"kMRMediaRemoteNowPlayingInfoTrackNumber";
NSString *kMRMediaRemoteNowPlayingInfoUniqueIdentifier = @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier";
NSString *kMRMediaRemoteNowPlayingInfoContentItemIdentifier = @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier";
NSString *kMRMediaRemoteNowPlayingInfoRadioStationHash = @"kMRMediaRemoteNowPlayingInfoRadioStationHash";
NSString *kMRMediaRemoteNowPlayingInfoMediaType = @"kMRMediaRemoteNowPlayingInfoMediaType";
NSString *kMRMediaRemoteNowPlayingInfoServiceIdentifier = @"kMRMediaRemoteNowPlayingInfoServiceIdentifier";
NSString *kMRMediaRemoteOptionMediaType = @"kMRMediaRemoteOptionMediaType";
NSString *kMRMediaRemoteOptionSourceID = @"kMRMediaRemoteOptionSourceID";
NSString *kMRMediaRemoteOptionTrackID = @"kMRMediaRemoteOptionTrackID";
NSString *kMRMediaRemoteOptionStationID = @"kMRMediaRemoteOptionStationID";
NSString *kMRMediaRemoteOptionStationHash = @"kMRMediaRemoteOptionStationHash";
NSString *kMRMediaRemoteRouteDescriptionUserInfoKey = @"kMRMediaRemoteRouteDescriptionUserInfoKey";
NSString *kMRMediaRemoteRouteStatusUserInfoKey = @"kMRMediaRemoteRouteStatusUserInfoKey";

CFStringRef MRMediaRemoteSendCommand = CFSTR("MRMediaRemoteSendCommand");

CFStringRef MRMediaRemoteSetPlaybackSpeed = CFSTR("MRMediaRemoteSetPlaybackSpeed");
CFStringRef MRMediaRemoteSetElapsedTime = CFSTR("MRMediaRemoteSetElapsedTime");
CFStringRef MRMediaRemoteSetShuffleMode = CFSTR("MRMediaRemoteSetShuffleMode");
CFStringRef MRMediaRemoteSetRepeatMode = CFSTR("MRMediaRemoteSetRepeatMode");

CFStringRef MRMediaRemoteRegisterForNowPlayingNotifications = CFSTR("MRMediaRemoteRegisterForNowPlayingNotifications");
CFStringRef MRMediaRemoteUnregisterForNowPlayingNotifications = CFSTR("MRMediaRemoteUnregisterForNowPlayingNotifications");
CFStringRef MRMediaRemoteGetNowPlayingApplicationPID = CFSTR("MRMediaRemoteGetNowPlayingApplicationPID");
CFStringRef MRMediaRemoteGetNowPlayingClient = CFSTR("MRMediaRemoteGetNowPlayingClient");
CFStringRef MRMediaRemoteGetNowPlayingInfo = CFSTR("MRMediaRemoteGetNowPlayingInfo");
CFStringRef MRMediaRemoteGetNowPlayingApplicationIsPlaying = CFSTR("MRMediaRemoteGetNowPlayingApplicationIsPlaying");

NSString *kMRNowPlayingClientUserInfoKey = @"kMRNowPlayingClientUserInfoKey";

static NSString *MediaRemoteFrameworkBundleURL = @"/System/Library/PrivateFrameworks/MediaRemote.framework";

@implementation MediaRemote
@synthesize sendCommand;
@synthesize setPlaybackSpeed;
@synthesize setElapsedTime;
@synthesize setShuffleMode;
@synthesize setRepeatMode;
@synthesize registerForNowPlayingNotifications;
@synthesize unregisterForNowPlayingNotifications;
@synthesize getNowPlayingApplicationPID;
@synthesize getNowPlayingClient;
@synthesize getNowPlayingInfo;
@synthesize getNowPlayingApplicationIsPlaying;
-(id)init
{
    if (!(self = [super init])) {
        return nil;
    }
    CFURLRef bundleURL = (__bridge CFURLRef)[NSURL fileURLWithPath:MediaRemoteFrameworkBundleURL];
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL);
    if (!bundle) {
        return nil;
    }
    sendCommand = (MRMediaRemoteSendCommand_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteSendCommand);
    setPlaybackSpeed = (MRMediaRemoteSetPlaybackSpeed_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteSetPlaybackSpeed);
    setElapsedTime = (MRMediaRemoteSetElapsedTime_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteSetElapsedTime);
    setShuffleMode = (MRMediaRemoteSetShuffleMode_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteSetShuffleMode);
    setRepeatMode = (MRMediaRemoteSetRepeatMode_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteSetRepeatMode);
    registerForNowPlayingNotifications = (MRMediaRemoteRegisterForNowPlayingNotifications_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteRegisterForNowPlayingNotifications);
    unregisterForNowPlayingNotifications = (MRMediaRemoteUnregisterForNowPlayingNotifications_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteUnregisterForNowPlayingNotifications);
    getNowPlayingApplicationPID = (MRMediaRemoteGetNowPlayingApplicationPID_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteGetNowPlayingApplicationPID);
    getNowPlayingClient = (MRMediaRemoteGetNowPlayingClient_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteGetNowPlayingClient);
    getNowPlayingInfo = (MRMediaRemoteGetNowPlayingInfo_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteGetNowPlayingInfo);
    getNowPlayingApplicationIsPlaying = (MRMediaRemoteGetNowPlayingApplicationIsPlaying_t)CFBundleGetFunctionPointerForName(bundle, MRMediaRemoteGetNowPlayingApplicationIsPlaying);
    return self;
}
@end
