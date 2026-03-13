// Creates a virtual display on headless macOS (CI runners without a physical monitor).
// Uses the private CGVirtualDisplay API from CoreGraphics.
// The display stays alive as long as this process runs.
//
// Build: clang -framework Foundation -framework CoreGraphics -o create-virtual-display create-virtual-display.m
// Usage: ./create-virtual-display &

#import <Foundation/Foundation.h>
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned int width = 1920;
        unsigned int height = 1080;

        // Verify the private classes exist
        if (!NSClassFromString(@"CGVirtualDisplay")) {
            fprintf(stderr, "ERROR: CGVirtualDisplay API not available on this system\n");
            return 1;
        }

        // Create display mode
        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60.0];
        if (!mode) {
            fprintf(stderr, "ERROR: Failed to create CGVirtualDisplayMode\n");
            return 1;
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
        settings.modes = @[mode];

        BOOL ok = [display applySettings:settings];
        if (!ok) {
            fprintf(stderr, "ERROR: Failed to apply display settings\n");
            return 1;
        }

        printf("Virtual display created: %ux%u@60Hz (displayID: %u)\n", width, height, display.displayID);
        printf("PID: %d\n", getpid());
        fflush(stdout);

        // Keep alive so the display persists
        dispatch_main();
    }
    return 0;
}
