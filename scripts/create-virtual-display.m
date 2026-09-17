// Creates a virtual display on headless macOS (CI runners without a physical monitor).
// Uses the private CGVirtualDisplay API from CoreGraphics.
// The display stays alive as long as this process runs and can optionally churn
// through multiple display modes after a start signal file appears.
//
// Build: clang -framework Foundation -framework CoreGraphics -o create-virtual-display create-virtual-display.m
// Usage: ./create-virtual-display &

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <unistd.h>
#import <objc/runtime.h>

// Private CoreGraphics classes (declared here since they're not in public headers)
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) unsigned int displayID;
@end

static NSArray<NSDictionary<NSString *, NSNumber *> *> *defaultModeSpecs(void) {
    return @[
        @{@"width": @1920, @"height": @1080},
    ];
}

static void writeString(NSString *value, NSString *path) {
    if (path.length == 0) { return; }
    NSError *error = nil;
    BOOL ok = [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok && error) {
        fprintf(stderr, "ERROR: Failed to write %s (%s)\n", path.UTF8String, error.localizedDescription.UTF8String);
    }
}

static NSDictionary<NSString *, NSNumber *> *parseModeSpec(NSString *raw) {
    NSArray<NSString *> *parts = [raw.lowercaseString componentsSeparatedByString:@"x"];
    if (parts.count != 2) { return nil; }

    NSInteger width = parts[0].integerValue;
    NSInteger height = parts[1].integerValue;
    if (width <= 0 || height <= 0) { return nil; }

    return @{
        @"width": @(width),
        @"height": @(height),
    };
}

static NSArray<NSDictionary<NSString *, NSNumber *> *> *parseModeList(NSString *raw) {
    if (raw.length == 0) { return defaultModeSpecs(); }

    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *modes = [NSMutableArray array];
    for (NSString *token in [raw componentsSeparatedByString:@","]) {
        NSString *trimmed = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) { continue; }
        NSDictionary<NSString *, NSNumber *> *parsed = parseModeSpec(trimmed);
        if (!parsed) {
            fprintf(stderr, "ERROR: Invalid mode spec: %s\n", trimmed.UTF8String);
            return nil;
        }
        [modes addObject:parsed];
    }

    if (modes.count == 0) {
        return defaultModeSpecs();
    }
    return modes;
}

static NSString *modeLabel(CGDisplayModeRef mode) {
    return [NSString stringWithFormat:@"%zux%zu", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
}

static NSArray *resolveRequestedModes(CGDirectDisplayID displayID, NSArray<NSDictionary<NSString *, NSNumber *> *> *requestedModes) {
    NSArray *availableModes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(displayID, NULL));
    if (availableModes.count == 0) {
        fprintf(stderr, "ERROR: No CoreGraphics display modes found for display %u\n", displayID);
        return nil;
    }

    NSMutableArray *resolved = [NSMutableArray array];
    for (NSDictionary<NSString *, NSNumber *> *modeSpec in requestedModes) {
        size_t requestedWidth = modeSpec[@"width"].unsignedIntegerValue;
        size_t requestedHeight = modeSpec[@"height"].unsignedIntegerValue;

        id matched = nil;
        for (id candidate in availableModes) {
            CGDisplayModeRef mode = (__bridge CGDisplayModeRef)candidate;
            if (CGDisplayModeGetWidth(mode) == requestedWidth &&
                CGDisplayModeGetHeight(mode) == requestedHeight) {
                matched = candidate;
                break;
            }
        }

        if (!matched) {
            fprintf(stderr, "ERROR: Requested display mode %zux%zu not available\n", requestedWidth, requestedHeight);
            fprintf(stderr, "Available modes:");
            for (id candidate in availableModes) {
                CGDisplayModeRef mode = (__bridge CGDisplayModeRef)candidate;
                fprintf(stderr, " %s", modeLabel(mode).UTF8String);
            }
            fprintf(stderr, "\n");
            return nil;
        }

        [resolved addObject:matched];
    }

    return resolved;
}

static NSString *argumentValue(NSArray<NSString *> *arguments, NSString *flag) {
    NSString *prefix = [flag stringByAppendingString:@"="];
    for (NSUInteger i = 0; i < arguments.count; i += 1) {
        NSString *arg = arguments[i];
        if ([arg isEqualToString:flag]) {
            if (i + 1 < arguments.count) {
                return arguments[i + 1];
            }
            return @"";
        }
        if ([arg hasPrefix:prefix]) {
            return [arg substringFromIndex:prefix.length];
        }
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];

        NSString *modesArgument = argumentValue(arguments, @"--modes");
        NSArray<NSDictionary<NSString *, NSNumber *> *> *modeSpecs = parseModeList(modesArgument);
        if (!modeSpecs) {
            return 1;
        }

        NSString *readyPath = argumentValue(arguments, @"--ready-path") ?: @"";
        NSString *displayIDPath = argumentValue(arguments, @"--display-id-path") ?: @"";
        NSString *startPath = argumentValue(arguments, @"--start-path") ?: @"";
        NSString *donePath = argumentValue(arguments, @"--done-path") ?: @"";
        NSInteger iterations = MAX(0, [argumentValue(arguments, @"--iterations") integerValue]);
        NSString *intervalArgument = argumentValue(arguments, @"--interval-ms");
        NSInteger intervalMs = intervalArgument.length > 0 ? intervalArgument.integerValue : 40;
        useconds_t intervalMicros = (useconds_t)(MAX(1, intervalMs) * 1000);
        NSString *startDelayArgument = argumentValue(arguments, @"--start-delay-ms");
        NSInteger startDelayMs = startDelayArgument.length > 0 ? startDelayArgument.integerValue : 0;

        unsigned int width = 0;
        unsigned int height = 0;
        for (NSDictionary<NSString *, NSNumber *> *spec in modeSpecs) {
            width = MAX(width, spec[@"width"].unsignedIntValue);
            height = MAX(height, spec[@"height"].unsignedIntValue);
        }

        // Verify the private classes exist
        if (!NSClassFromString(@"CGVirtualDisplay")) {
            fprintf(stderr, "ERROR: CGVirtualDisplay API not available on this system\n");
            return 1;
        }

        NSMutableArray *modes = [NSMutableArray array];
        for (NSDictionary<NSString *, NSNumber *> *spec in modeSpecs) {
            CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:spec[@"width"].unsignedIntValue
                                                                               height:spec[@"height"].unsignedIntValue
                                                                          refreshRate:60.0];
            if (!mode) {
                fprintf(stderr, "ERROR: Failed to create CGVirtualDisplayMode\n");
                return 1;
            }
            [modes addObject:mode];
        }

        // Configure descriptor
        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.name = @"CI Virtual Display";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.sizeInMillimeters = CGSizeMake(530, 300);
        descriptor.vendorID = 0x1234;
        descriptor.productID = 0x5678;
        descriptor.serialNum = 0x0001;
        descriptor.queue = dispatch_get_main_queue();

        // Create virtual display
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display) {
            fprintf(stderr, "ERROR: Failed to create CGVirtualDisplay\n");
            return 1;
        }

        // Apply settings with display mode
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 0;
        settings.modes = modes;

        BOOL ok = [display applySettings:settings];
        if (!ok) {
            fprintf(stderr, "ERROR: Failed to apply display settings\n");
            return 1;
        }

        printf("Virtual display created: %ux%u@60Hz (displayID: %u)\n", width, height, display.displayID);
        printf("PID: %d\n", getpid());
        fflush(stdout);
        writeString([NSString stringWithFormat:@"%u\n", display.displayID], displayIDPath);
        writeString(@"ready\n", readyPath);

        if (iterations > 0 && modeSpecs.count > 1) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (startDelayMs > 0) {
                    usleep((useconds_t)(startDelayMs * 1000));
                } else if (startPath.length > 0) {
                    while (![[NSFileManager defaultManager] fileExistsAtPath:startPath]) {
                        usleep(20 * 1000);
                    }
                }

                NSArray *resolvedModes = resolveRequestedModes(display.displayID, modeSpecs);
                if (resolvedModes.count < 2) {
                    writeString(@"error:no_modes\n", donePath);
                    return;
                }

                CGError setError = CGDisplaySetDisplayMode(display.displayID, (__bridge CGDisplayModeRef)resolvedModes.firstObject, NULL);
                if (setError != kCGErrorSuccess) {
                    fprintf(stderr, "ERROR: Failed to set initial display mode (%d)\n", setError);
                    writeString([NSString stringWithFormat:@"error:%d\n", setError], donePath);
                    return;
                }

                for (NSInteger i = 0; i < iterations; i += 1) {
                    NSUInteger targetIndex = (NSUInteger)((i + 1) % resolvedModes.count);
                    id targetMode = resolvedModes[targetIndex];
                    CGError churnError = CGDisplaySetDisplayMode(display.displayID, (__bridge CGDisplayModeRef)targetMode, NULL);
                    if (churnError != kCGErrorSuccess) {
                        fprintf(stderr, "ERROR: Failed to switch display mode at iteration %ld (%d)\n", (long)i, churnError);
                        writeString([NSString stringWithFormat:@"error:%d\n", churnError], donePath);
                        return;
                    }
                    usleep(intervalMicros);
                }

                writeString(@"done\n", donePath);
            });
        }

        // Keep alive so the display persists
        dispatch_main();
    }
    return 0;
}
