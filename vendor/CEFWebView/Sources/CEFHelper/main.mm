// CEFHelper — subprocess entry (GPU, utility, network, etc.)
// Links CEFWrapper so library load + CefExecuteProcess match the main app.

#import <Foundation/Foundation.h>
#import "CEFWrapper.h"

int main(int argc, char* argv[]) {
    @autoreleasepool {
        int code = [CEFWrapper executeSubprocessWithArgc:argc argv:argv];
        if (code >= 0) {
            return code;
        }
        // Not a CEF subprocess role (should not happen for this binary alone).
        return 1;
    }
}
