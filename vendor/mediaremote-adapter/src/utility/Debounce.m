// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

#import "Debounce.h"

@interface Debounce ()

@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong, nullable) dispatch_block_t pendingBlock;
@property(nonatomic, assign, readwrite) NSTimeInterval delay;

@end

@implementation Debounce

- (instancetype)initWithDelay:(NSTimeInterval)delay
                        queue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _delay = MAX(0.0, delay);
        _queue = queue ?: dispatch_get_main_queue();
    }
    return self;
}

- (void)call:(dispatch_block_t)block {
    [self cancel];
    self.pendingBlock = dispatch_block_create(DISPATCH_BLOCK_BARRIER, block);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)),
        self.queue, self.pendingBlock);
}

- (void)cancel {
    if (self.pendingBlock) {
        dispatch_block_cancel(self.pendingBlock);
        self.pendingBlock = nil;
    }
}

@end
