# Device control: real iPhone and Android in the phone tab

Status: research done, implementation not started. Owner: a528 (Oct 22, 2026).
Related: plans/cmux-next/phone.md, plans/cmux-next/simulators-DESIGN.md, a513 (simulator polish).

## 1. Why the iPhone tab shows the screen but takes no input

- `XcodePhoneBackend.capabilities(for:)` gives a real device (`.device` mode) only
  `[.screenshot, .recordVideo]`
  (Packages/macOS/CmuxNext/Sources/CmuxNextPhone/XcodePhoneBackend.swift).
- `PhoneTabView.stillFrameTouch` drops every click when the device does not have `.touch`
  (Packages/macOS/CmuxNext/Sources/CmuxNextPhone/PhoneTabView.swift), and `send` refuses
  the input in `XcodePhoneBackend.send` (`guard id.mode == .simulator`).
- The tab gives no error message, so it looks broken. The status line says only
  "still frame". Fix in UI terms: say why input is off and what turns it on.
- The screen is a still `devicectl device capture screenshot` (about 1.4 s for each frame),
  refreshed only after a change event. There is no live stream for real devices.

## 2. Why the "shell" is missing

Default picked: "shell" means the device frame (bezel) around the screen.
`PhoneScreenView` draws the bare screen with an 18 pt corner radius. Device chrome
was planned and never built (simulators-DESIGN.md section 12, item 5).
Xcode installs device chrome art for each model, so cmux can read it at run time
and needs to bundle nothing. If the user meant something else (a terminal on the
phone), only Android has one (`adb shell`). iOS has no shell.

## 3. How TapKit works (public docs and its public Mac app, read only)

- A Mac app (macOS 14.6+). The iPhone stays plugged in by USB and unlocked. Nothing
  is installed on the phone.
- Screen: the iPhone over USB shows as a CoreMediaIO screen-capture camera
  (this is why the app asks for Camera permission). This is the documented
  QuickTime path.
- Input: the Mac acts as a Bluetooth HID pointer and keyboard paired with the
  iPhone. AssistiveTouch on the phone turns pointer clicks into taps. Setup turns
  on AssistiveTouch and pairs over Bluetooth (the app asks for Bluetooth permission).
- Limits that TapKit states: the phone must stay unlocked (Auto-Lock: Never),
  typing is US-ASCII only and at most 100 characters, and the Mac keyboard does not type on the phone.
- The agent reaches it through their cloud (REST + MCP). Screenshots pass through
  and are stored on their servers. Price: $49 for each phone each month.

## 4. What we measured on this Mac (Xcode 27.1, iOS 27.0.1, iPhone 16 Pro over Wi-Fi)

| Measurement | Result |
|---|---|
| `devicectl device capture screenshot` | about 1.4 s for each frame |
| CoreDevice in-process screenshot (Xcode's own path) | p50 298 ms, min 263 ms, max 499 ms (10 frames) |
| Hardware buttons (lock and wake) through CoreDevice | work, also on a locked phone |
| Touch through CoreDevice while the phone is locked | no effect (expected; see below) |
| Wi-Fi tunnel after the phone locks | drops; a retry after 2-5 s connects again |

Xcode 27's own Devices window ("View Device Screen", `devices://device/open`) lets
a person use an unlocked, paired iPhone from the Mac. Its UI text says: "Make sure
the device is unlocked, connected, and its screen is on". So touch on a real
device needs the phone unlocked. This is a security rule, not a bug.

## 5. Plan (in order)

1. Honest UI now: the iPhone tab says "Input needs …" with one button for the
   next step, instead of dropping clicks without a message. Bezel from Xcode's
   installed device chrome. A failing test first (capabilities and tab state for a
   `.device` phone).
2. Real iPhone, the supported route first: **macOS iPhone Mirroring**
   (System Applications/iPhone Mirroring.app). It gives live video and real
   input (click, scroll, keyboard) with Apple's own trust and lock rules. cmux
   can show and drive that window through the existing computer-use layer
   (cmux-cua: screenshot of the window, click and type into it in the background).
   It works when the phone is locked nearby, and the user unlocks it on the Mac.
   This is the default route for people who are not power users.
3. Developer route (Xcode installed, Developer Mode on): the CoreDevice path that
   Xcode's Devices window uses, in a separate helper process (so a changed Xcode
   cannot crash cmux). It is gated behind a capability probe. It is off when the
   probe fails, and it is never enabled without a live check on an unlocked phone.
4. Android: already done in v1 (adb input + live H.264 from `screenrecord`).
   Next: physical-device check with `adb devices -l`, scrcpy-style reconnect
   after `screenrecord`'s 3-minute limit, and the `adb shell` terminal tab
   (`cmux phone shell`).
5. Agent use: every route goes through `PhoneService.send`, so `cmux phone tap/
   swipe/type/button/screenshot` and the `app_phone_*` MCP tools work for Chiefs
   with no new verbs.

## 6. Privacy rules (all routes)

- Screens and input stay on this Mac. Nothing goes to a cloud. This is unlike TapKit.
- A visible "Being controlled by <agent>" badge on the tab while an agent drives
  the phone, and Esc or the tab's Stop button takes control back.
- Agents never type passwords or passcodes. The phone tab refuses `phone.type`
  while a secure text field is focused, if the route can detect it.

## 7. Needs the user (phone in hand)

- Unlock the iPhone, set Auto-Lock to Never for the test, and keep it on Wi-Fi or USB.
- For the Mirroring route: open iPhone Mirroring once and finish Apple's setup.
- Then a live check runs: tap, swipe, type, Home, and a before/after video into
  ~/fun/cmux-galleries/device-control.
