# Hardware Memory Tagging

Hardware memory tagging (Memory Integrity Enforcement) uses ARM Memory Tagging Extension (MTE) to detect use-after-free and out-of-bounds memory access at runtime.

## What It Does

Each memory allocation and pointer receives an embedded **tag** value. When your app accesses memory through a pointer, the hardware checks that the pointer's tag matches the allocation's tag. If the tags don't match — because of a use-after-free, buffer overflow, or other memory corruption — the app crashes instead of performing the unsafe access.

## What Vulnerabilities It Mitigates

- **Use-after-free** — accessing memory after it has been freed (the freed memory gets a new tag)
- **Heap buffer overflow** — accessing memory beyond the allocated region (adjacent allocations have different tags)
- **Out-of-bounds access** — reading or writing past array boundaries
- **Double-free** — freeing memory that has already been freed

## How to Enable

**Xcode UI:** Signing & Capabilities > Enhanced Security > Memory Safety > click "Enable Hardware Memory Tagging"

**Entitlement:** `com.apple.security.hardened-process.checked-allocations`

### Soft Mode.

Soft mode produces **simulated crashes** (crash reports) instead of actually terminating the app. Use this to find memory bugs without impacting users.

**Entitlement:** `com.apple.security.hardened-process.checked-allocations.soft-mode`

Soft mode is enabled by default when you first enable hardware memory tagging. After reviewing crash reports and fixing issues, disable soft mode for enforcement.

**Xcode UI:** Under Memory Safety, deselect "Enable Soft Mode for Memory Tagging"

### Debugging Diagnostics

For detailed diagnostics during development, navigate to Scheme Editor > Run > Diagnostics > enable "Hardware Memory Tagging".

### Additional Entitlements

- `com.apple.security.hardened-process.checked-allocations.enable-pure-data` — extends tagging to pure data allocations
- `com.apple.security.hardened-process.checked-allocations.no-tagged-receive` — prevents receiving tagged pointers from other processes

## Code Changes Required

None for basic adoption. Hardware memory tagging is a runtime enforcement mechanism — no source code annotations are needed. However, code with latent memory bugs will safely abort (or produce simulated crash reports in soft mode).

## How to Disable

**Xcode UI:** Under Memory Safety, deselect "Enable Hardware Memory Tagging"

Remove the `com.apple.security.hardened-process.checked-allocations` entitlement.

## Platform Availability

- **Hardware:** Available on iPhone 17, iPhone 17 Pro, iPhone 17 Pro Max, iPhone 17 Air, M5-based Macs, iPads, and Vision Pro — and subsequent releases.

## Performance and Stability Impact

- **Performance:** Moderate overhead due to hardware tag checking on every memory access. Profile your app.
- **Stability:** Code with latent memory bugs **will crash**. Use soft mode first to identify and fix issues before enforcing.
- **Adoption path:** Enable soft mode > review simulated crash reports > fix memory bugs > disable soft mode for production.
