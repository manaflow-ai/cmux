// Copyright (c) 2025 Alexander5015
// This file is licensed under the BSD 3-Clause License.

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

@protocol RemoteCommandCenterDelegateListener <NSObject>
- (void)didReceivePlayCommand;
- (void)didReceivePauseCommand;
@end

@interface NowPlayingInfoDelegate : NSObject

@property(nonatomic, readonly) MPNowPlayingInfoCenter *center;

- (void)updateMetadataWithTitle:(NSString *)title
                         artist:(NSString *)artist
                       duration:(NSTimeInterval)duration;
- (void)setPlaybackRate:(float)rate elapsedTime:(NSTimeInterval)time;

@end

@interface RemoteCommandCenterDelegate : NSObject

@property(nonatomic, weak) id<RemoteCommandCenterDelegateListener> listener;

- (instancetype)initWithListener:
    (id<RemoteCommandCenterDelegateListener>)listener;

@end

@interface NowPlayingPublishTest
    : NSObject <RemoteCommandCenterDelegateListener>

@property(nonatomic, strong, readonly)
    NowPlayingInfoDelegate *nowPlayingDelegate;
@property(nonatomic, strong, readonly)
    RemoteCommandCenterDelegate *commandDelegate;
@property(nonatomic, assign, readonly) BOOL isPlaying;
@property(nonatomic, assign, readonly) NSTimeInterval elapsedTime;
@property(nonatomic, strong, nullable, readonly) NSDate *playbackStartDate;
@property(nonatomic, assign, readonly) NSTimeInterval totalDuration;

- (void)updateNowPlayingInfo;

@end

NS_ASSUME_NONNULL_END