# WebKit Certificate Bypass Flag Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--ignore-certificate-errors` CLI flag and `browser.cert_bypass` socket command to bypass WebKit TLS certificate validation for local dev servers.

**Architecture:** A new `BrowserCertBypassSettings` enum in `BrowserPanel.swift` owns the flag state. The CLI flag sets an in-memory `runtimeOverride` at startup. The socket command also sets `runtimeOverride` (session-only, no persistence). UserDefaults provides an out-of-band persistence layer readable by `isEnabled()`. The existing `BrowserNavigationDelegate.didReceive challenge` method in `BrowserPanel.swift` checks the flag and accepts any server trust challenge when enabled.

**Tech Stack:** Swift, WKWebView/WebKit, UserDefaults, NSURLAuthenticationMethodServerTrust

**Spec:** `docs/superpowers/specs/2026-03-10-webkit-cert-bypass-design.md`

---

## Chunk 1: Core Flag + TLS Bypass

### Task 1: Add `BrowserCertBypassSettings` to `BrowserPanel.swift`

**Files:**
- Modify: `Sources/Panels/BrowserPanel.swift` (insert after line 529, before `BrowserUserAgentSettings`)

- [ ] **Step 1: Add the enum**

In `Sources/Panels/BrowserPanel.swift`, after the closing `}` of `browserShouldOpenURLExternally` (line 528) and before `enum BrowserUserAgentSettings` (line 530), insert:

```swift
enum BrowserCertBypassSettings {
    static let defaultsKey = "browserIgnoreCertificateErrors"
    // Set by --ignore-certificate-errors at launch or by browser.cert_bypass set (session-only).
    // Never written by this enum; callers set it directly.
    static var runtimeOverride: Bool? = nil

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if let override = runtimeOverride { return override }
        return defaults.bool(forKey: defaultsKey)
    }
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-cert-bypass" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/Panels/BrowserPanel.swift
git commit -m "feat: add BrowserCertBypassSettings enum"
```

---

### Task 2: Apply CLI flag at app startup

**Files:**
- Modify: `Sources/cmuxApp.swift` (inside `init()`, after line ~47 `Self.configureGhosttyEnvironment()`)

- [ ] **Step 1: Add CLI flag check to `cmuxApp.init()`**

In `Sources/cmuxApp.swift`, inside `init()` (around line 47, after `Self.configureGhosttyEnvironment()`), add:

```swift
if CommandLine.arguments.contains("--ignore-certificate-errors") {
    BrowserCertBypassSettings.runtimeOverride = true
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-cert-bypass" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/cmuxApp.swift
git commit -m "feat: apply --ignore-certificate-errors CLI flag at startup"
```

---

### Task 3: Bypass TLS in `BrowserNavigationDelegate.didReceive challenge`

**Files:**
- Modify: `Sources/Panels/BrowserPanel.swift` (lines 3802–3818)

- [ ] **Step 1: Modify the challenge handler**

Replace the existing `webView(_:didReceive:completionHandler:)` implementation (lines 3802–3818 in `BrowserPanel.swift`):

**Old:**
```swift
func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
    // WKWebView rejects all authentication challenges by default when this
    // delegate method is not implemented (.rejectProtectionSpace). This
    // breaks TLS client-certificate flows such as Microsoft Entra ID
    // Conditional Access, which verifies device compliance via a client
    // certificate stored in the system keychain by MDM enrollment.
    //
    // By returning .performDefaultHandling the system's standard URL-loading
    // behaviour takes over: the keychain is searched for matching client
    // identities, MDM-installed root CAs are trusted, and any configured SSO
    // extensions (e.g. Microsoft Enterprise SSO) can intercept the challenge.
    completionHandler(.performDefaultHandling, nil)
}
```

**New:**
```swift
func webView(
    _ webView: WKWebView,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
    // When certificate bypass is active (--ignore-certificate-errors or browser.cert_bypass set true),
    // unconditionally trust server certificates. This covers self-signed and unknown-root certs
    // common in local development (e.g. https://localhost:8443). Only server trust challenges
    // are bypassed; client cert and other challenge types still use default handling.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
       BrowserCertBypassSettings.isEnabled(),
       let serverTrust = challenge.protectionSpace.serverTrust {
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        return
    }

    // WKWebView rejects all authentication challenges by default when this
    // delegate method is not implemented (.rejectProtectionSpace). This
    // breaks TLS client-certificate flows such as Microsoft Entra ID
    // Conditional Access, which verifies device compliance via a client
    // certificate stored in the system keychain by MDM enrollment.
    //
    // By returning .performDefaultHandling the system's standard URL-loading
    // behaviour takes over: the keychain is searched for matching client
    // identities, MDM-installed root CAs are trusted, and any configured SSO
    // extensions (e.g. Microsoft Enterprise SSO) can intercept the challenge.
    completionHandler(.performDefaultHandling, nil)
}
```

- [ ] **Step 2: Verify build compiles**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-cert-bypass" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Smoke test with tagged build**

```bash
./scripts/reload.sh --tag cert-bypass
```

Launch the app and open a browser split with a self-signed HTTPS URL. With `--ignore-certificate-errors`, it should load; without it, the existing cert error page should appear.

- [ ] **Step 4: Commit**

```bash
git add Sources/Panels/BrowserPanel.swift
git commit -m "feat: bypass TLS cert validation when BrowserCertBypassSettings.isEnabled()"
```

---

## Chunk 2: Socket Command

### Task 4: Add `browser.cert_bypass` socket commands

**Files:**
- Modify: `Sources/TerminalController.swift`
  - Dispatch cases: around line 1983 (end of browser.* block)
  - Handler function: near other `v2Browser*` helpers (around line 7300+)

- [ ] **Step 1: Add dispatch cases**

In `Sources/TerminalController.swift`, in the v2 command switch statement, after the last `browser.*` case (around line 1983), add:

```swift
case "browser.cert_bypass":
    return v2Result(id: id, self.v2BrowserCertBypass(params: params))
```

- [ ] **Step 2: Add handler function**

Near the other `v2Browser*` helper functions (around line 7300+), add:

```swift
private func v2BrowserCertBypass(params: [String: Any]) -> V2CallResult {
    let action = (params["action"] as? String) ?? (params["args"] as? [String])?.first ?? ""
    switch action {
    case "get":
        return .ok(["enabled": BrowserCertBypassSettings.isEnabled()])
    case "set":
        let rawValue = (params["args"] as? [String])?.dropFirst().first
            ?? (params["value"] as? String)
            ?? (params["enabled"] as? Bool).map { $0 ? "true" : "false" }
        guard let rawValue else {
            return .err(code: "invalid_params", message: "Missing value: use 'set true' or 'set false'", data: nil)
        }
        switch rawValue.lowercased() {
        case "true", "1", "yes":
            BrowserCertBypassSettings.runtimeOverride = true
            return .ok(["enabled": true])
        case "false", "0", "no":
            BrowserCertBypassSettings.runtimeOverride = false
            return .ok(["enabled": false])
        default:
            return .err(code: "invalid_params", message: "Invalid value '\(rawValue)': use 'true' or 'false'", data: nil)
        }
    default:
        return .err(code: "invalid_params", message: "Unknown action '\(action)': use 'get' or 'set'", data: nil)
    }
}
```

**How callers invoke it via CLI:**
```bash
# Get current state
cmux browser.cert_bypass --action get

# Enable (session-only, does not persist)
cmux browser.cert_bypass --action set --value true

# Disable
cmux browser.cert_bypass --action set --value false
```

- [ ] **Step 3: Verify build compiles**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-cert-bypass" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/TerminalController.swift
git commit -m "feat: add browser.cert_bypass get/set socket command"
```

---

### Task 5: Add socket test

**Files:**
- Create: `tests_v2/test_browser_cert_bypass.py`

- [ ] **Step 1: Write the test**

Create `tests_v2/test_browser_cert_bypass.py`:

```python
#!/usr/bin/env python3
"""Regression: browser.cert_bypass get/set socket commands."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        # get returns a bool
        result = c._call("browser.cert_bypass", {"action": "get"})
        _must(isinstance(result.get("enabled"), bool),
              f"browser.cert_bypass get should return enabled bool, got: {result}")

        initial = result["enabled"]

        # set true
        r = c._call("browser.cert_bypass", {"action": "set", "value": "true"})
        _must(r.get("enabled") is True, f"set true should return enabled=true, got: {r}")

        # get reflects the change
        r = c._call("browser.cert_bypass", {"action": "get"})
        _must(r.get("enabled") is True, f"get after set true should return true, got: {r}")

        # set false
        r = c._call("browser.cert_bypass", {"action": "set", "value": "false"})
        _must(r.get("enabled") is False, f"set false should return enabled=false, got: {r}")

        r = c._call("browser.cert_bypass", {"action": "get"})
        _must(r.get("enabled") is False, f"get after set false should return false, got: {r}")

        # restore initial state
        c._call("browser.cert_bypass", {"action": "set", "value": "true" if initial else "false"})

        print("PASS: browser.cert_bypass get/set")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Commit**

```bash
git add tests_v2/test_browser_cert_bypass.py
git commit -m "test: browser.cert_bypass get/set socket commands"
```

> **Note:** Do not run this test locally. It requires a running cmux instance. Trigger via CI: `gh workflow run test-e2e.yml` (see cmuxterm-hq CLAUDE.md).

---

## Final: Tag & PR

- [ ] Push branch and open PR targeting `main`

```bash
git push origin HEAD
gh pr create --title "feat: --ignore-certificate-errors flag for WebKit cert bypass" \
  --body "Adds Chrome-style TLS cert bypass for local dev servers with self-signed certs.

## Changes
- \`BrowserCertBypassSettings\` enum in \`BrowserPanel.swift\` (runtime override + UserDefaults fallback)
- \`--ignore-certificate-errors\` CLI flag (session-only, checked at startup in \`cmuxApp.init()\`)
- \`BrowserNavigationDelegate.didReceive challenge\` bypasses server trust when flag is active
- \`browser.cert_bypass get/set\` socket commands (session-only, no persistence)
- Socket regression test in \`tests_v2/test_browser_cert_bypass.py\`

## Usage
\`\`\`bash
# Launch with bypass active
cmux --ignore-certificate-errors

# Toggle at runtime (session-only)
cmux browser.cert_bypass --action set --value true

# Persistent bypass (external, survives restarts)
defaults write ai.manaflow.cmux browserIgnoreCertificateErrors -bool true
\`\`\`"
```
