// Loaded only into the isolated CLI subprocess. Never changes macOS privacy.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <unistd.h>

static NSString *resolverTripwire(id object, SEL selector) {
    const char note[] = "CMUX_TEST_HOSTNAME_RESOLVER_CALLED\n";
    write(STDERR_FILENO, note, sizeof(note) - 1);
    return @"resolver-must-not-run.invalid";
}

__attribute__((constructor)) static void installTripwire(void) {
    @autoreleasepool {
        Method method = class_getInstanceMethod([NSHost class], @selector(name));
        method_setImplementation(method, (IMP)resolverTripwire);
    }
}
