# Read-Only Platform Memory

Marks regions of memory used by the platform for internal state (such as the dynamic loader) as read-only, preventing tampering.

## What It Does

Informs the system to mark memory regions in your process that the platform uses for its internal state as **read-only**. This primarily protects the dynamic loader (dyld) internal data structures from being modified by an attacker who has achieved code execution in your process.

## What Vulnerabilities It Mitigates

- **Dyld state tampering** — an attacker modifying the dynamic loader's internal data to redirect library loading
- **Runtime metadata corruption** — overwriting platform-internal data structures to alter program behavior
- **Post-exploitation persistence** — modifying loader state to maintain control after initial exploitation

## How to Enable

**Xcode UI:** Signing & Capabilities > Enhanced Security > check "Enable Read-Only Platform Memory"

**Entitlement:** `com.apple.security.hardened-process.dyld-ro`

Enabled by default when you add the Enhanced Security capability.

## Code Changes Required

**Usually none.** In most applications, this entitlement requires no code changes.

The only exception: if your app **modifies data in protected memory regions** (for example, modifying the value of `const` data sections), the system will crash your app. Fix: remove the code that writes to read-only memory.

## How to Disable

**Xcode UI:** Uncheck "Enable Read-Only Platform Memory" in the Enhanced Security capability

## Platform Availability

- iOS, iPadOS, macOS, visionOS
- Available on all supported hardware

## Performance and Stability Impact

- **Performance:** None. Memory is marked read-only at load time; no ongoing runtime checks.
- **Stability:** Unless your code writes to `const` data sections or platform-internal memory (which is already a bug), this has zero impact.

## Why This Feature Is Low-Risk

Read-only platform memory is one of the safest Enhanced Security features:
- No runtime cost
- No code changes for well-behaved code
- Only crashes code that was already doing something wrong (writing to `const` memory)
- Provides meaningful protection against post-exploitation techniques

Enable this early alongside compiler warnings and stack zero init.
