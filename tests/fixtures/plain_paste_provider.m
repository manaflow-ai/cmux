#import <AppKit/AppKit.h>
#import <unistd.h>

// Separate provider process: hanging it must never strand the consumer process.
@interface PlainPasteProvider : NSObject <NSPasteboardItemDataProvider>
@property(nonatomic, strong) NSDictionary *configuration;
@end

@implementation PlainPasteProvider
- (void)pasteboard:(NSPasteboard *)pasteboard item:(NSPasteboardItem *)item provideDataForType:(NSPasteboardType)type {
    [@"requested" writeToFile:self.configuration[@"requested"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *behavior = self.configuration[@"behavior"];
    if ([behavior isEqualToString:@"stall"]) {
        while (1) { pause(); }
    }
    if ([behavior isEqualToString:@"replace"]) {
        [pasteboard clearContents];
        [pasteboard setString:@"new generation" forType:NSPasteboardTypeString];
    }
    if (![behavior isEqualToString:@"missing"]) {
        [item setString:self.configuration[@"text"] forType:type];
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { return 64; }
        NSDictionary *config = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        NSPasteboard *board = [NSPasteboard pasteboardWithName:config[@"name"]];
        [board clearContents];
        NSPasteboardItem *item = [NSPasteboardItem new];
        PlainPasteProvider *provider = [PlainPasteProvider new];
        provider.configuration = config;
        for (NSString *type in config[@"representations"]) {
            if ([type isEqualToString:@"NSFilenamesPboardType"]) { continue; }
            [item setString:config[@"representations"][type] forType:type];
        }
        if (config[@"behavior"] != nil) {
            [item setDataProvider:provider forTypes:@[NSPasteboardTypeString]];
        }
        [board writeObjects:@[item]];
        if (config[@"representations"][@"NSFilenamesPboardType"] != nil) {
            [board addTypes:@[@"NSFilenamesPboardType"] owner:nil];
            [board setPropertyList:@[@"/tmp/plain-paste-fixture"] forType:@"NSFilenamesPboardType"];
        }
        NSDictionary *ready = @{ @"generation": @(board.changeCount) };
        [[NSJSONSerialization dataWithJSONObject:ready options:0 error:nil]
            writeToFile:config[@"ready"] atomically:YES];
        // A named board and isolated process keep fixtures off the user's clipboard.
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
