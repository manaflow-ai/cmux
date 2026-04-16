# macOS JIT Entitlements for Chromium V8

## Problem

Chromium's V8 JavaScript engine requires **JIT (Just-In-Time) compilation**, which allocates memory with write+execute permissions. On macOS with Hardened Runtime, this is blocked by default, causing the renderer process to crash with `EXC_BAD_ACCESS (SIGSEGV)` the instant V8 initializes.

**Symptoms:**
- Browser loads but pages show blank/empty content
- No errors or logs from the renderer process
- Crash report shows `CrBrowserMain` thread crashing in V8 code (`_v8_internal_Node_Print`)
- Page "loads" but takes <1 second with empty title

## Solution

Add a **Code Signing Entitlements** file to the Xcode target with three required entitlements:

### File: `ChromiumWebView/ChromiumWebView.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Required for Chromium's V8 JavaScript engine (JIT compilation) -->
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<!-- Required for V8 interpreter/JIT edge cases -->
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<!-- Allows debugger to attach and enables Mach IPC for helper processes -->
	<key>com.apple.security.get-task-allow</key>
	<true/>
</dict>
</plist>
```

### Xcode Configuration

1. Select the **ChromiumWebView** target
2. Go to **Build Settings**
3. Search for **"Code Signing Entitlements"**
4. Set the value to: `ChromiumWebView/ChromiumWebView.entitlements`
5. Apply to **both Debug and Release** configurations

### Why Each Entitlement

| Entitlement | Purpose |
|---|---|
| `com.apple.security.cs.allow-jit` | Allows V8 to allocate memory with write+execute permissions for JIT code generation. **Critical for JavaScript execution.** |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Covers edge cases in V8's interpreter and JIT boundary conditions. V8 sometimes writes executable code outside the main JIT region. |
| `com.apple.security.get-task-allow` | Enables Mach task port access between processes. Fixes "Unable to obtain a task name port right" errors from CEF helper processes. Also required for debugger attachment in development builds. |

## Testing

After adding entitlements and rebuilding:

1. Browser should render pages correctly
2. Console logs should show page title changes
3. Crash reports should no longer show V8 crashes
4. No "Unable to obtain a task name port right" errors

## References

- [Apple Security and Hardened Runtime](https://developer.apple.com/documentation/security)
- [V8 JIT on macOS](https://v8.dev/docs/build-gn)
- [Chromium on macOS](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)
