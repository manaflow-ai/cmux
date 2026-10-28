#!/usr/bin/env bash
# Link every public ABI declaration the pinned Tailscale posture/DNS paths use.
# Run on a cross-build job after macos-cross.sh toolchain, never on an agent host.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# macos-cross.sh keeps XC_ROOT local to its process. Reuse its documented
# default when this check runs as the next workflow command.
xc_root=${XC_ROOT:-${RUNNER_TEMP:-$HOME}/macos-cross}
sysroot="$xc_root/sysroot"
llvm=${LLVM_BIN:-/usr/lib/llvm-19/bin}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/probe.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <Security/Security.h>
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
    CFTypeRef result = 0; CFErrorRef error = 0; SecTrustRef trust = 0;
    SecCertificateRef cert = 0; SecKeyRef key = 0; CFArrayRef array = 0;
    CFStringRef text = CFStringCreateWithCString(0, "", kCFStringEncodingUTF8);
    CFStringGetCStringPtr(text, kCFStringEncodingUTF8);
    CFDictionaryRef dict = CFDictionaryCreate(0, 0, 0, 0, 0, 0);
    array = CFArrayCreate(0, 0, 0, 0); CFArrayGetCount(array);
    CFArrayGetValueAtIndex(array, 0); CFArrayGetValues(array, (CFRange){0, 0}, 0);
    CFDataRef data = CFDataCreate(0, 0, 0); CFDataGetBytePtr(data); CFDataGetLength(data);
    CFStringCreateExternalRepresentation(0, text, kCFStringEncodingUTF8, 0);
    CFRetain(data); CFErrorCopyDescription(error); CFErrorGetCode(error);
    SecItemCopyMatching(dict, &result); SecItemDelete(dict); SecPKCS12Import(data, dict, &array);
    SecIdentityCopyCertificate(0, &cert); SecIdentityCopyPrivateKey(0, &key);
    SecCertificateCopyData(cert); SecPolicyRef policy = SecPolicyCreateSSL(0, 0);
    SecTrustCreateWithCertificates(cert, policy, &trust);
    SecTrustEvaluateWithError(trust, &error); SecTrustCopyCertificateChain(trust);
    SecKeyCreateSignature(key, kSecKeyAlgorithmRSASignatureDigestPSSSHA256, data, &error);
    return 0;
}
C
for arch in arm64 x86_64; do
  "$llvm/clang" --target="$arch-apple-macos14.0" -isysroot "$sysroot" -fuse-ld=lld \
    -framework CoreFoundation -framework IOKit -framework SystemConfiguration -framework Security -lresolv \
    "$work/probe.c" -o "$work/probe-$arch"
  "$llvm/llvm-objdump" --macho --dylibs-used "$work/probe-$arch"
done
