// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#ifndef MEDIAREMOTEADAPTER_UTILITY_DEBOUNCE_H
#define MEDIAREMOTEADAPTER_UTILITY_DEBOUNCE_H

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Debounce : NSObject

@property(nonatomic, assign, readonly) NSTimeInterval delay;
- (instancetype)initWithDelay:(NSTimeInterval)delay
                        queue:(nullable dispatch_queue_t)queue;
- (void)call:(dispatch_block_t)block;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

#endif // MEDIAREMOTEADAPTER_UTILITY_DEBOUNCE_H
