# cmux iOS

Minimal iOS/iPadOS shell for the cmux mobile sync workstream.

Current phase:

- sign-in gate
- QR/manual pairing surface
- isolated preview host data
- workspace list
- workspace detail
- terminal dropdown
- preview-only workspace and terminal creation

There is no production networking in this phase. The preview host is local in-memory state so the UI and simulator tests can stabilize before Tailscale transport lands.

Build and reload the simulator:

```bash
ios/scripts/reload.sh --tag ios4
```

Run package tests:

```bash
xcodebuild -workspace ios/cmuxMobile.xcworkspace -scheme cmuxMobile -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/cmux-ios4-tests test -skip-testing:cmuxMobileUITests
```
