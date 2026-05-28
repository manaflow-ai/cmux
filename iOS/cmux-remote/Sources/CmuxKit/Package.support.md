# Why is there no `Package.swift` here?

CmuxKit is built as an iOS framework inside the XcodeGen-managed Xcode
project, **not** as a standalone Swift package. The reason: Citadel's
dependency tree (swift-nio-ssh, swift-crypto) and a few of CmuxKit's
own imports — `Logging`, `Collections`, `AsyncAlgorithms` — are all
available either way, but we need uniform handling of iOS-only frameworks
(`UserNotifications`, `ActivityKit`, `WidgetKit`) downstream in the app
target, and a single Xcode project keeps the scheme + signing + entitlements
story trivial.

If you need to compile or test the protocol layer headlessly on macOS, do:

```bash
xcodebuild test \
  -scheme CmuxKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0'
```

This matches what CI will run.
