#import <Foundation/Foundation.h>

__attribute__((constructor))
static void RegisterLegacyFocusHistoryTestDefaults(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"focusHistoryIncludesPanesAndTabs": @YES,
    }];
}
