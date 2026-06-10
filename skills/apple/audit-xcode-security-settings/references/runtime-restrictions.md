# Additional Run-time Restrictions

Adds runtime checks on dynamic libraries your app loads and Mach messages your app receives, preventing common code injection and privilege escalation attacks.

## What It Does

Informs the system to perform additional checks on:

1. **Dynamic libraries** — validates libraries your app or extension loads at runtime
2. **Mach messages** — validates Mach messages your app or extension receives from other processes

Potentially insecure situations are turned into crashes rather than allowing an attacker to gain privileged access through Mach ports.

## What Vulnerabilities It Mitigates

- **Dylib injection** — an attacker loading malicious dynamic libraries into your process
- **Mach port attacks** — exploiting Mach IPC to send crafted messages to your process
- **Privilege escalation via IPC** — using Mach messages to gain access to your app's privileges or data

## How to Enable

**Xcode UI:** Signing & Capabilities > Enhanced Security > check "Enable Additional Runtime Platform Restrictions"

**Entitlement:** `com.apple.security.hardened-process.platform-restrictions-string`

Enabled by default when you add the Enhanced Security capability.

## Code Changes Required

**If your app uses XPC for IPC** (and doesn't use raw Mach IPC traps): likely no code changes needed.

**If your app uses raw Mach IPC traps:** you may need to update your code. The runtime restrictions turn potentially insecure Mach messaging patterns into crashes. For details on what patterns to fix, see [Conforming to Mach IPC security restrictions](https://developer.apple.com/documentation/xcode/conforming-to-mach-ipc-security-restrictions).

**If your app has no explicit IPC mechanism:** no code changes needed.

## How to Disable

**Xcode UI:** Uncheck "Enable Additional Runtime Platform Restrictions" in the Enhanced Security capability

## Platform Availability

- iOS, iPadOS, macOS, visionOS
- Available on all supported hardware

## Performance and Stability Impact

- **Performance:** Negligible. The checks run at library load time and message receive time, not on every operation.
- **Stability:** Apps using XPC or no IPC are unaffected. Apps using raw Mach IPC may crash if they use insecure messaging patterns — review and fix these before enabling.

## Decision Guide

| Your IPC approach | Impact | Action needed |
|---|---|---|
| No IPC | None | Safe to enable |
| XPC only | None | Safe to enable |
| Mach IPC via higher-level APIs | Low | Test, review for issues |
| Raw Mach IPC traps | Moderate | Read Mach IPC conformance guide, fix insecure patterns |
