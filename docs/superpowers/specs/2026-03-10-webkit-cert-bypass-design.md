# WebKit Certificate Bypass Flag

**Date:** 2026-03-10
**Status:** Approved
**Use case:** Developer tooling — local dev servers with self-signed/unknown-root HTTPS certs

## Summary

Add an `--ignore-certificate-errors` CLI flag (analogous to Chrome's) that bypasses WebKit TLS validation. Also overridable at runtime via socket command `browser.cert_bypass set`.

## Design

### `BrowserCertBypassSettings` (new enum in `BrowserPanel.swift`)

```swift
enum BrowserCertBypassSettings {
    static let defaultsKey = "browserIgnoreCertificateErrors"
    static var runtimeOverride: Bool? = nil

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if let override = runtimeOverride { return override }
        return defaults.bool(forKey: defaultsKey)
    }
}
```

**Precedence:**
1. `runtimeOverride` — set by `--ignore-certificate-errors` at launch, or overwritten by socket `set` (both session-only)
2. UserDefaults `browserIgnoreCertificateErrors` — persistent, written externally (e.g. `defaults write`)

### CLI flag — app startup

In `cmuxApp.swift` (app init):

```swift
if CommandLine.arguments.contains("--ignore-certificate-errors") {
    BrowserCertBypassSettings.runtimeOverride = true
}
```

### TLS bypass — `BrowserNavigationDelegate`

Modify `webView(_:didReceive:completionHandler:)` in `BrowserPanel.swift`:

```swift
if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
   BrowserCertBypassSettings.isEnabled(),
   let serverTrust = challenge.protectionSpace.serverTrust {
    completionHandler(.useCredential, URLCredential(trust: serverTrust))
    return
}
completionHandler(.performDefaultHandling, nil)
```

When bypass is active, cert challenges are accepted before WebKit fails the load — existing cert error pages are never triggered.

### Socket command — `TerminalController.swift`

```
browser.cert_bypass get        → {"enabled": true|false}  (reflects effective state)
browser.cert_bypass set true   → {"enabled": true}   (sets runtimeOverride, session only)
browser.cert_bypass set false  → {"enabled": false}  (sets runtimeOverride, session only)
```

`set` does not write to UserDefaults. It overwrites the `--ignore-certificate-errors` CLI flag for the remainder of the session.

## Out of scope

- Settings UI toggle
- Per-tab or per-host granularity (flag is app-global, matching Chrome behavior)
- Certificate pinning or custom trust anchors
