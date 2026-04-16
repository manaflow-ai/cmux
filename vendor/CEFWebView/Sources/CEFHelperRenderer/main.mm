// CEFHelperRenderer — renderer subprocess entry (same logic as CEFHelper; CEF selects role via argv).

#import <Foundation/Foundation.h>
#import "CEFWrapper.h"

int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSLog(@"🚀 CEFHelperRenderer main() called with argc=%d", argc);
        for (int i = 0; i < argc; i++) {
            NSLog(@"   argv[%d]: %s", i, argv[i] ? argv[i] : "(null)");
        }
        NSLog(@"   Calling CEFWrapper.executeSubprocessWithArgc:argv:");

        int code = [CEFWrapper executeSubprocessWithArgc:argc argv:argv];
        NSLog(@"   CEFWrapper.executeSubprocessWithArgc returned: %d", code);

        if (code >= 0) {
            NSLog(@"✅ CEFHelperRenderer exiting with code: %d", code);
            return code;
        }
        NSLog(@"❌ CEFHelperRenderer: not a subprocess, returning 1");
        return 1;
    }
}
