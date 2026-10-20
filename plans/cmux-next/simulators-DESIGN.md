# Simulators and emulators in cmux-next

Status: v1 in progress (iOS live screen and input, Android over adb). Owner
module: `Packages/macOS/CmuxNext/Sources/CmuxNextPhone` (+ `CmuxNextPhoneTests`).
Builds on `plans/cmux-next/phone.md` (the phone tab, recordings, Send to Chief).
Request (2026-10-20): "we need the ios and android simulator stuff built into
cmux; reimplement what cmux-classic has from first principles, better".

## 1. What classic cmux has (inventory)

`Packages/macOS/CmuxSimulator` on `main`: about 430 Swift files (34k lines),
210 test files (20k lines), plus ObjC sources compiled with `clang` at run
time. iOS only. No Android code anywhere.

| Area | Classic |
|---|---|
| Devices | toolbar picker over `simctl list/boot/bootstatus/shutdown`; one booted iPhone/iPad per pane |
| Frames | a worker process (the cmux binary re-run with `--cmux-simulator-worker`) loads CoreSimulator + SimulatorKit, registers `registerScreenCallbacksWithUUID:…` on the display descriptor, renders each IOSurface frame with `CIContext` into a POSIX shared-memory triple ring (seqlock), `notify_post`s; the app maps the ring, copies each frame into a `CGImage`, sets `CALayer.contents`. Paced at 30 ms (16 ms after input). |
| Input | worker: Xcode 27 DTUHID XPC (`IndigoDigitizerEvent`, `IndigoKeyboardButtonEvent`, `IndigoButtonEvent`) or legacy `SimDeviceLegacyHIDClient` + `IndigoHIDMessageFor*`; normalized 0–1 points; rotation by a raw 112-byte Purple mach message; scroll wheel turned into paced touch drags; keys paced with 30 ms sleeps |
| Lifecycle | length-prefixed JSON over the worker's pipes, 3 s ping watchdog, per-request timeouts, one auto restart then a "crash fuse"; device switch replaces the worker; hidden pane stops publishing |
| Features | screenshots, recordings, `log stream`, apps (install, launch, terminate, open URL, media, push), status bar, appearance and accessibility settings, location routes, privacy (`simctl privacy` plus direct `TCC.db` edits), camera injection (an injector dylib compiled at run time), AX tree via private `AXPTranslator`, Web Inspector over `webinspectord_sim`, phone streaming v1/v2 |
| CLI | `cmux simulator type/tap/gesture/multitouch/swipe/button/rotate/…`, `cmux ios list/context/select/screenshot`, `simulator.*` and `mobile.simulator.*` socket methods |

What was bad:

- **Two copies per frame.** GPU→CPU readback into the ring, then a second
  memcpy into a `CGImage`, at up to 60 fps. The IOSurface was already a
  shareable GPU buffer.
- **The worker was the complexity.** About 60 mutable fields in the worker
  client (replay, proofs, revisions, camera permits), and a long run of race
  fixes in the first PR (#7857, 837 files) ("Close simulator routing and
  deadline races", "Reject stale simulator discovery results").
- **Sleeps as synchronization.** Gesture, key and button pacing slept; a
  display-refresh timer was the fallback when `notify` failed; phone stream v2
  still runs a 3 s watchdog loop.
- **Fragile across Xcode versions.** #10009 (67 files) to get Xcode 16 back;
  SimulatorKit moved folders in Xcode 27; scalar returns read with hand-cast
  `objc_msgSend` after probing encodings.
- **Hacks.** Run-time clang, `sqlite3` writes to `TCC.db`, raw mach messages.
- **iOS only.** No Android at all.

## 2. First principles

1. A simulator is a phone, not a special pane. One pane kind ("phone tab",
   `InternalPageID.phone`, route `sim:<udid>` / `avd:<name>` / `adb:<serial>`
   / `dev:<udid>`) shows any phone: iOS simulator, Android emulator, USB
   Android phone, real iPhone. The daemon stores only the route, so moves,
   splits, restore and reopen already work (no Rust change).
2. One service, one action path. `PhoneService` is the only place that does
   anything to a phone. The tab, the palette, `cmux phone …` and the MCP
   `app_phone_*` tools all call the same actions (`PhoneActionCatalog`).
   Raw-pixel open and screenshot actions are person-only until agents have
   authenticated device scope.
3. Use what the platform already gives. Xcode ships `simctl` and SimulatorKit;
   the Android SDK ships `adb` and `emulator`. cmux bundles no tools, no
   images, no runtimes.
4. Zero copies, zero work when hidden. The simulator renders into an
   IOSurface; Core Animation can draw an IOSurface directly. So the frame path
   is: SimulatorKit frame callback → `layer.setContentsChanged()`. Nothing is
   copied, encoded or polled. When the tab is hidden (tab switch, parked pane,
   occluded or minimized window) the tab unregisters the callbacks.
5. Capability, not version checks. Every private call checks
   `respondsToSelector:` first; a missing selector turns a capability off
   (`PhoneCapabilities`), and the tab hides the control or falls back to still
   frames. The UI never offers a control that fails.
6. Points, not pixels. Taps, swipes and accessibility frames share one space:
   iOS points, Android dp. An agent reads `cmux phone ui`, takes an element's
   frame center and taps it, on any screen density or scale.

## 3. Architecture

```
CmuxNextApp
  PhoneHandlers (actions) ── PhonePageTab (InternalPageProvider: makeView, route, restore)
        │                             │
CmuxNextPhone                         ▼
  PhoneService (@MainActor @Observable) ── PhoneTabView ── PhoneScreenView (CALayer: IOSurface or still)
        │  backend: PlatformPhoneBackend (actor)         │ mouse → touches, keys → HID, visibility → start/stop
        │     ├─ XcodePhoneBackend (simctl/devicectl; HID seam)
        │     └─ AndroidPhoneBackend (actor; adb/emulator)
        └─ live: SimulatorKitHID (@MainActor; SimulatorKit in-process)
              ├─ SimulatorKitRuntime (dlopen CoreSimulator + SimulatorKit, SimDevice by UDID)
              ├─ SimulatorScreenSource (framebuffer callbacks → IOSurface)
              └─ SimulatorHIDTransport (DTUHID XPC, else legacy Indigo client)
```

Seams for tests: `PhoneCommandRunning` (fake argv runner),
`SimulatorHIDSending` (fake HID), injected `Clock` for gesture pacing,
`AndroidSDK.locate(environment:home:fileExists:)`.

### In-process, not a worker

Classic isolated SimulatorKit in a worker. The cost (pipes, protocol,
supervision, replay, crash fuse, two copies per frame) was most of its 34k
lines and most of its bugs. The risk it protected against is an Objective-C
exception or a crash inside a private framework. v1 removes the reason for
those: every selector is checked before it is sent, scalar returns are read
through their type encoding, and nothing is called on a background queue.
If crash reports show SimulatorKit faults, the fallback is a small helper
process that hands the app the IOSurface once (`IOSurfaceCreateMachPort`) and
forwards input; the frame path stays zero-copy. That is a later step, only
with evidence.

## 4. iOS

| Feature | How |
|---|---|
| List, boot, shut down | `simctl list devices -j`, `simctl boot`, `simctl shutdown` |
| Live view | `SimDevice.io.ioPorts[].descriptor` → `registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:` on the main queue; the built-in display (`screenProperties.isDefault`, else `screenType == 0`); its `framebufferSurface` becomes `CALayer.contents`; each callback calls `setContentsChanged()` |
| Touch | Xcode 27: `SimDevice lookup:` `com.apple.coredevice.feature.remote.hid.digitizer` → XPC `IndigoDigitizerEvent` (`pointOne`, `eventType` 0/1/2); older: `SimDeviceLegacyHIDClient` + `IndigoHIDMessageForMouseNSEvent` (target 0x32). Points normalized 0–1. Tab: mouse down/drag/up; CLI: `phone tap/swipe` paced on an injected clock (one move per 16 ms frame) |
| Keyboard | HID keyboard usages (`IndigoKeyboardButtonEvent` / `IndigoHIDMessageForKeyboardArbitrary`). Tab: Mac key codes → usages; Cmd shortcuts stay with cmux. CLI `phone type`: a US-layout encoder; text with characters a US keyboard cannot type goes through `simctl pbcopy` then Cmd+V, so any script types |
| Hardware buttons | consumer-page usages home 0x40, lock 0x30, Siri 0xCF, volume 0xE9/0xEA (`IndigoButtonEvent`); legacy maps home/lock/Siri to Indigo event sources |
| Rotation | not in v1 (classic needed a raw Purple mach message); Android rotates. Planned: `GSEvent` orientation through the same HID service if Xcode 27 exposes it, else the mach message behind a capability |
| Screenshot / record | `simctl io screenshot`, `simctl io recordVideo --codec=h264` (SIGINT finalizes) |
| Logs | `cmux phone logs` opens a terminal tab running `xcrun simctl spawn <udid> log stream --style compact`; recordings keep an NDJSON log |
| Apps, deep links | `simctl install`, `simctl launch`, `simctl openurl` |
| Appearance, locale, location | `simctl ui appearance`, `simctl spawn defaults write -g AppleLanguages/AppleLocale` (apps see it on next launch), `simctl location set` |
| Accessibility tree | not in v1 for iOS. Planned: the private `AXPTranslator` (AccessibilityPlatformTranslation), as classic did, into the same `PhoneElement` tree Android returns |

## 5. Android

| Feature | How |
|---|---|
| SDK | `ANDROID_HOME`, `ANDROID_SDK_ROOT`, else `~/Library/Android/sdk`; needs `platform-tools/adb`, `emulator/emulator` |
| List | `emulator -list-avds` + `adb devices -l`; a running emulator's AVD from `adb emu avd name`; OS from `getprop ro.build.version.release`. Ids: `avd:<name>`, `adb:<serial>` |
| Boot | `emulator -avd <name> -port <next free even port> -no-window -no-audio -no-boot-anim` (headless: the tab draws it), then `adb wait-for-device` and the device-side `sys.boot_completed` wait |
| Shut down | `adb emu kill` |
| Touch, keys | `input tap/swipe` in pixels (dp × `wm density`/160), `input text` (shell-quoted, `%s` for spaces), `input keyevent` (HOME, BACK, POWER, VOLUME_*, APP_SWITCH, ASSIST) |
| Screen | v1: still frames (`adb exec-out screencap -p`) after every action and on click. Next: live H.264 from `adb exec-out screenrecord --output-format=h264 -` into `AVSampleBufferDisplayLayer` (hardware decode, no copy), restarted at its time limit; then the emulator's gRPC `streamScreenshot` with its shared-memory transport |
| Record, logs | `screenrecord --output-format=h264` to the recording; `logcat -v threadtime` into the recording, `logcat -v color` in the logs terminal tab |
| Apps, deep links | `adb install -r`, `monkey -p <package> -c LAUNCHER 1`, `am start -a VIEW -d <url>` |
| Appearance, locale, location, rotate | `cmd uimode night yes/no`; `adb root` + `setprop persist.sys.locale` + zygote restart (emulators); `adb emu geo fix <lon> <lat>`; `adb emu rotate` |
| Accessibility tree | `uiautomator dump /dev/tty` → `PhoneElement` tree with frames in dp |

## 6. CLI and MCP (agents)

All are `PhoneActionCatalog` actions, so each is a `cmux phone <verb>` CLI
command and an `app_phone_<verb>` MCP tool. `--device` takes an id or a name;
without it, the recorded phone, else the first booted simulator.

`phone open` and `phone screenshot` are advertised for discovery but fail closed
for CLI/MCP callers: opening starts a raw frame stream, and screenshots return raw
pixels. A person can run both inside cmux; automation needs a future authenticated,
device-scoped principal before either is re-enabled.

| Verb | Does | Answers |
|---|---|---|
| `phone list` | every phone with capabilities | `devices` (JSON), `count`, `missing` (xcode, android-sdk) |
| `phone open` | opens (or switches) the phone tab | |
| `phone boot` / `phone shutdown` | | |
| `phone screenshot [--path]` | PNG | `path` |
| `phone tap --x --y` | tap in points | |
| `phone swipe --fromX --fromY --toX --toY [--seconds]` | | |
| `phone type --text` | types text | |
| `phone button --button home\|lock\|volume-up\|volume-down\|siri\|back\|app-switch` | | |
| `phone ui` | accessibility tree (Android in v1) | `tree` (JSON: role, label, identifier, value, frame, children), `elements` |
| `phone appearance --appearance light\|dark`, `phone location --latitude --longitude`, `phone locale --locale ja_JP` | | |
| `phone install --path`, `phone launch --app`, `phone open-url --url`, `phone paste --text` | | |
| `phone rotate` | quarter turn (Android) | |
| `phone logs` | log stream in a new terminal tab beside | |
| `phone record` / `phone stop` / `phone feedback` | recordings and Send to Chief (phone.md) | |

`pane new-simulator` (the existing pane-menu action) opens the phone tab.

## 7. Multiple devices

Each phone tab shows one phone; open more tabs (or split panes) for more
phones. Every action names its phone with `--device`, and `SimulatorKitHID`
keeps one input transport and one screen source per UDID, so two simulators
stream and take input side by side. The phone page keeps one tab per window
today (phone.md); v1.1 lifts that to one tab per phone.

## 8. Pane focus (with a255)

The screen view becomes first responder on click and takes keys while it
has focus; Cmd shortcuts pass to cmux. The keyboard-only simulator actions
(`simulatorHome`, rotate, appearance, software keyboard) need the
`simulatorFocused` context, which nothing sets yet. a255 owns the central
pane-focus model; when it lands, the phone tab publishes `simulatorFocused`
from that one place and the five actions bind to `PhoneService`.

## 9. Performance

- Visible iOS tab: one main-thread callback per simulator frame that only
  marks the layer dirty. No copy, no encode, no allocation.
- Hidden tab: callbacks unregistered: no work at all. Visibility is the
  view's own state (`viewDidHide`, window occlusion), not a timer.
- Still frames (Android v1, iOS without SimulatorKit): one capture after each
  action, never on a timer.
- No polling anywhere. The one wait loop is Android's device-side boot
  check, which adb documents as the boot signal.

## 10. Missing tools

`PlatformPhoneBackend` lists whatever platform answers. No Xcode: iOS rows
are missing, `phone list` answers `missing: xcode`, iOS actions fail with
"Xcode is not installed …". No Android SDK: Android actions fail with "the
Android SDK is not installed; install Android Studio or set ANDROID_HOME".
SimulatorKit that does not load (a new Xcode changed it): the iOS tab shows
still frames and touch is off; nothing crashes. No phones at all: the tab
says how to add one in Xcode or Android Studio.

## 11. Tests

- `CmuxNextPhoneTests` (fleet, Swift Testing): Android backend against a fake
  runner and SDK root (`AndroidPhoneBackendTests`), simctl controls and
  platform routing (`SimulatorControlsTests`), iOS touch/key/button planning
  and pane click mapping against a fake HID (`SimulatorLiveInputTests`).
- Live checks on a mini with a booted simulator (class `simulator`): frame
  callbacks deliver an IOSurface, a tap reaches the guest, and a rendered
  phone-tab screenshot. Android checks need the SDK on a mini (not installed
  on the minis on 2026-10-20).

## 12. Not in v1 (next steps, in order)

1. Android live H.264 screen (`screenrecord` → `AVSampleBufferDisplayLayer`).
2. iOS accessibility tree (AXPTranslator) and iOS rotation.
3. `simulatorFocused` and the keyboard actions (after a255).
4. One tab per phone; a device picker that boots on pick.
5. Device chrome (bezels) from the shared device presets (a129).
6. Privacy grants (`simctl privacy`), push (`simctl push`), status bar.
7. Web Inspector for simulator Safari/WKWebView (classic had one).
