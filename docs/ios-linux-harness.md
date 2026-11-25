# iOS tests on a Linux host

Run cmux's iOS package tests on a Linux lane VM, with no Mac and no fleet simulator, through
`scripts/ios-linux-harness.sh`. It boots an iOS-simulator-shaped target, builds a `Packages/iOS`
package against it and runs that package's tests there.

```bash
scripts/ios-linux-harness.sh boot                      # a device record, a data container, the shims
scripts/ios-linux-harness.sh test CmuxTabsKit          # one package; --filter Suite/test narrows it
scripts/ios-linux-harness.sh survey                    # every Packages/iOS package, one row each
scripts/ios-linux-harness.sh erase                     # drop every device's data
```

Each run ends with one `ios-linux-harness:` JSON line: package, build and test result, seconds, whether
the shims were on, the device UDID, the test counts, and the first compiler error when the build failed.
Logs are in the booted device's `logs/` folder (`status` prints where).

The toolchain is `swift` on PATH, else `/opt/swift` (every lane VM has one), else run the script inside
`public.ecr.aws/docker/library/swift:6.2-noble`, the image `swift-linux-packages.yml` uses.

## What is iOS-like and what isn't

This is not the iOS Simulator. Apple's simulator runs iOS binaries against the iOS SDK's frameworks on
a Darwin kernel through CoreSimulator; none of that exists on Linux, and no QEMU or Darling route runs
it today. Nothing here runs UIKit, SwiftUI, the app's view controllers, XCUITest, or the app binary.

What the harness does give a test:

| Simulator trait | Here |
| --- | --- |
| A device: name, model identifier, runtime version, UDID | `boot --device NAME --model ID --runtime VERSION`, default `iPhone 16 (Linux harness)`, `iPhone17,3`, 17.0 |
| A per-device data container | `Documents`, `Library/Caches`, `Library/Preferences`, `tmp`; the test process's HOME and TMPDIR point into it, so each boot starts empty |
| The simulator process environment | `SIMULATOR_DEVICE_NAME`, `SIMULATOR_MODEL_IDENTIFIER`, `SIMULATOR_RUNTIME_VERSION`, `SIMULATOR_UDID`, `SIMULATOR_SHARED_RESOURCES_DIRECTORY`, plus `CMUX_IOS_LINUX_HARNESS=1` |
| Apple frameworks | Only shims for a small used surface: `CoreGraphics` re-exports Foundation's `CGFloat`, `CGPoint`, `CGSize` and `CGRect` and adds `CGVector` ([shims](../scripts/ios-linux-harness/shims)) |
| `#if os(iOS)` code | Not compiled. A Linux build takes the non-Apple branch of every `#if os(...)` / `canImport(...)` |

So a pass here means the package's platform-independent logic (models, protocols, stores, layout math)
is right on this toolchain. It doesn't prove the iOS build compiles or that the UI works; those still
take a Mac: `cmux-ci compile-check --ref SHA --package NAME` for compiling, and the fleet simulator
([cmux-ios skill](../skills/cmux-ios/SKILL.md)) for the app.

## Which packages run

From `survey` on a lane VM (8 vCPU, toolchain 6.3.3), 2026-11-23, with a fresh device each side:

| Package | Shims off | Shims on | Blocked by |
| --- | --- | --- | --- |
| CmuxMobileShellModel | pass (436 tests) | pass | |
| CmuxMobilePairedMac | pass (45 tests) | pass | |
| CmuxMobileBilling | pass (48 tests) | pass | |
| CmuxTabsKit | build fails (`no such module 'CoreGraphics'`) | pass (72 tests) | |
| CmuxMobileSupport | build fails | build fails | unguarded `SwiftUI` imports, then `String(localized:bundle:)`, which Foundation lacks here |
| CmuxMobileRPC | build fails | build fails | CmuxMobileSupport |
| CmuxMobileTunnel | build fails | build fails | `Network` (NWConnection) |
| CmuxMobileSSH | build fails | build fails | CmuxMobileTunnel, `Security`, `LocalAuthentication` |
| CmuxConversation | build fails | build fails | `AVFoundation` in CmuxConversationCore, `SwiftUI` in CmuxSpinner |

3 of 9 `Packages/iOS` packages ran their tests here before the shims and 4 of 9 with them.
`cmux-next-ios/CmuxMobileKit` is out of reach for now: it names a gitignored binary target
(`CmuxMobileLinkFFI.xcframework`) and most of its targets import SwiftUI.

The per-target picture for every Swift package is `plans/cmux-next/swift-linux-inventory.md`; its
**shims** class is what this harness's shims are for.

## Adding a shim

A shim belongs here when the package uses a small, value-type surface of an Apple framework (geometry,
a logger) and the real behavior isn't what the test checks. Put one `.swift` file per module in
`scripts/ios-linux-harness/shims/` and add its compile line to `build_shims` in the script: a module with
code gets `-module-link-name` and a static library, as `CoreGraphics` does. If swift-testing declares a
cross-import overlay for that module name (as it does for CoreGraphics), add an empty
`_Testing_<Module>` module too, or every test that imports both fails with `no such module`. Run
`survey` with `CMUX_IOS_LINUX_NO_SHIMS=1` and without, and update the table above.

A UI framework (UIKit, SwiftUI) is not a shim: stubbing it would let view code compile while proving
nothing about it.
