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
typedef const void *CFTypeRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef const struct __CFString *CFStringRef;
typedef struct __CFDictionary *CFMutableDictionaryRef;
extern const CFAllocatorRef kCFAllocatorDefault;
#define kCFStringEncodingUTF8 ((CFStringEncoding)0x08000100)
#define CFSTR(value) ((CFStringRef)__builtin___CFStringMakeConstantString(value))
extern CFIndex CFStringGetLength(CFStringRef);
extern CFIndex CFStringGetMaximumSizeForEncoding(CFIndex, CFStringEncoding);
extern Boolean CFStringGetCString(CFStringRef, char *, CFIndex, CFStringEncoding);
extern void CFRelease(CFTypeRef);
