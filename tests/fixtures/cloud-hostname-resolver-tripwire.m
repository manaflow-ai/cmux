// Loaded only into the isolated CLI subprocess. Never changes macOS privacy.
#if CMUX_TEST_REMOTE_PROBE_CLIENT
#include <stdio.h>
#include <string.h>

int main(int argc, const char *argv[]) {
    if (argc != 3 || strcmp(argv[1], "remote-probe") != 0 ||
        strcmp(argv[2], "--json") != 0) {
        return 64;
    }
    fputs("{\"app\":\"cmux-tui\",\"capabilities\":[\"wireguard-hub\"]}\n", stdout);
    return ferror(stdout) == 0 ? 0 : 1;
}
#else
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
        const char note[] = "CMUX_TEST_HOSTNAME_TRIPWIRE_INSTALLED\n";
        write(STDERR_FILENO, note, sizeof(note) - 1);
    }
}
#endif
