// Minimal public C ABI used by the pinned libtailscale posture probe.
// This is not an Apple SDK header. Keep this surface limited to those calls;
// tests/test_tailnet_cross_link.sh links every declaration against our stubs.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
typedef signed long CFIndex;
typedef uint32_t CFStringEncoding;
typedef unsigned char Boolean;
// Keep opaque handles on one named pointer type.  cgo must permit the
// conversions used by the pinned certstore bridge (for example CFStringRef
// values in a CFTypeRef dictionary); distinct incomplete struct names turn
// those ABI-compatible conversions into compile errors in cgo.
typedef struct __CFType *CFTypeRef;
typedef CFTypeRef CFAllocatorRef;
typedef CFTypeRef CFStringRef;
typedef CFTypeRef CFMutableDictionaryRef;
extern const CFAllocatorRef kCFAllocatorDefault;
#define kCFStringEncodingUTF8 ((CFStringEncoding)0x08000100)
#define CFSTR(value) ((CFStringRef)__builtin___CFStringMakeConstantString(value))
extern CFIndex CFStringGetLength(CFStringRef);
extern CFIndex CFStringGetMaximumSizeForEncoding(CFIndex, CFStringEncoding);
extern Boolean CFStringGetCString(CFStringRef, char *, CFIndex, CFStringEncoding);
extern void CFRelease(CFTypeRef);
// Additional public ABI consumed by tailscale/certstore's pinned Darwin bridge.
typedef uint8_t UInt8;
typedef CFTypeRef CFArrayRef;
typedef CFTypeRef CFDataRef;
typedef CFTypeRef CFDictionaryRef;
typedef CFTypeRef CFErrorRef;
typedef CFTypeRef CFBooleanRef;
typedef struct { CFIndex location; CFIndex length; } CFRange;
typedef struct CFArrayCallBacks CFArrayCallBacks;
typedef struct CFDictionaryKeyCallBacks CFDictionaryKeyCallBacks;
typedef struct CFDictionaryValueCallBacks CFDictionaryValueCallBacks;
extern const CFBooleanRef kCFBooleanTrue;
extern CFTypeRef CFRetain(CFTypeRef);
extern CFArrayRef CFArrayCreate(CFAllocatorRef, const void **, CFIndex, const CFArrayCallBacks *);
extern CFIndex CFArrayGetCount(CFArrayRef);
extern const void *CFArrayGetValueAtIndex(CFArrayRef, CFIndex);
extern void CFArrayGetValues(CFArrayRef, CFRange, const void **);
extern CFDataRef CFDataCreate(CFAllocatorRef, const UInt8 *, CFIndex);
extern const UInt8 *CFDataGetBytePtr(CFDataRef);
extern CFIndex CFDataGetLength(CFDataRef);
extern CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void **, const void **, CFIndex, const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *);
extern CFStringRef CFErrorCopyDescription(CFErrorRef);
extern CFIndex CFErrorGetCode(CFErrorRef);
extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, CFStringEncoding);
extern const char *CFStringGetCStringPtr(CFStringRef, CFStringEncoding);
