#!/usr/bin/env bash
# Link every public ABI declaration the pinned Tailscale posture/DNS paths use.
# Run on a cross-build job after macos-cross.sh toolchain, never on an agent host.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
sysroot=${XC_ROOT:?run macos-cross.sh toolchain first}/sysroot
llvm=${LLVM_BIN:-/usr/lib/llvm-19/bin}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/probe.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
extern int res_9_ninit(void *);
extern int res_9_nsearch(void *, const char *, int, int, unsigned char *, int);
extern void res_9_nclose(void *);
int main(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOPlatformExpertDevice");
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, match);
    io_service_t newer = IOServiceGetMatchingService(kIOMainPortDefault, 0);
    CFStringRef value = IORegistryEntryCreateCFProperty(service, CFSTR("IOPlatformSerialNumber"), kCFAllocatorDefault, 0);
    CFIndex length = CFStringGetLength(value);
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    char *buffer = malloc(capacity);
    CFStringGetCString(value, buffer, capacity, kCFStringEncodingUTF8);
    CFRelease(value); free(buffer);
    IOObjectRelease(service); IOObjectRelease(newer);
    res_9_ninit(0); res_9_nsearch(0, "localhost", 0, 0, 0, 0); res_9_nclose(0);
    return 0;
}
C
for arch in arm64 x86_64; do
  "$llvm/clang" --target="$arch-apple-macos14.0" -isysroot "$sysroot" -fuse-ld=lld \
    -framework CoreFoundation -framework IOKit -framework SystemConfiguration -lresolv \
    "$work/probe.c" -o "$work/probe-$arch"
  "$llvm/llvm-objdump" --macho --dylibs-used "$work/probe-$arch"
done
