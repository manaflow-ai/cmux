// Minimal public C ABI for Tailscale's IOPlatformExpertDevice query.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
typedef unsigned int mach_port_t;
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;
typedef unsigned int IOOptionBits;
typedef int kern_return_t;
extern const mach_port_t kIOMainPortDefault;
extern const mach_port_t kIOMasterPortDefault;
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern io_service_t IOServiceGetMatchingService(mach_port_t, CFMutableDictionaryRef);
extern CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
extern kern_return_t IOObjectRelease(io_object_t);
