# Brief for UI agents (cmux-next mobile)

Worktree: `/Users/azizalbahar/Development/cmuxterm-hq/worktrees/nx-ios-app`
(branch `feat-cmux-next-ios-app`). Several agents edit this tree at once.

## Rules
- Edit only the target directories you own (named in your task). Never revert,
  stash, reformat or delete other agents' files. Commit only your own paths
  (`git add <paths> && git commit`), message ending
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; retry on index.lock.
  Do not push.
- Swift 6 language mode, iOS 26 SDK features (Liquid Glass: `.glassEffect`,
  `GlassEffectContainer`, `.buttonStyle(.glass)`), strict concurrency. Wrap every
  UI source file in `#if os(iOS)` ... `#endif` so `swift test` on macOS builds.
- Public package types need an instance surface (no caseless namespace enums or
  all-static public types).
- No sleeps for synchronization; drive animations with UIKit/SwiftUI springs and
  real callbacks. Respect Reduce Motion.
- Colors and metrics: `CNDesign` (`CNTheme.shared.palette`, `Color.cn(\.x)`).
  cmux-next rule: no accent hue except `highlight` (agent send button,
  switches). Use system fonts (SF Pro / SF Mono).
- Data: `CNTransport.HostClient` / `HostConnection` and `CNCore` models
  (read their sources; `PROTOCOL.md` is the wire contract). Develop against
  `CNMockHost` (`MockHost().makeConnector()`), which is a full in-process host
  with demo data; the shell agent wires the real WebRTC connector.
- Each UI module exposes one public root, e.g. `ConversationsRoot(connection:)`,
  usable from both shells (drawer and tabs). Do not build app-level navigation
  chrome (tab bar, drawer); your root may push within its own
  `NavigationStack`/`UINavigationController` and must accept an optional
  leading toolbar item (the drawer shell injects a hamburger button) via
  `CNShellChrome` environment value: define nothing yourself; the shell agent
  defines `CNShellChrome` in CNDesign (`@Entry var cnLeadingBarItem: AnyView?`).
  Until it lands, just leave room for it.

## Build, run, look
This laptop is overloaded: never run xcodebuild locally. Use
`ios-next/scripts/remote-ios.sh` (builds on another Mac, headless simulator,
one slot per agent; use your own `--slot` name):
```
ios-next/scripts/remote-ios.sh build --slot <you> --scheme Drawer
ios-next/scripts/remote-ios.sh run   --slot <you> --scheme Drawer --env CMUX_NEXT_DEV_SCREEN=<screen>
ios-next/scripts/remote-ios.sh shot  --slot <you> --out /tmp/nxios/<you>-x.png
ios-next/scripts/remote-ios.sh video --slot <you> --seconds 6 --out /tmp/nxios/<you>.mp4
ios-next/scripts/remote-ios.sh axe   --slot <you> -- tap -x 200 -y 400       # also swipe, type, describe-ui
ios-next/scripts/remote-ios.sh sim   --slot <you> -- ui \$UDID appearance dark
```
The full app may not compile while others are mid-change; if a failure is in
another agent's target, wait briefly and retry, or temporarily build with
your target reachable through a DEBUG dev-screen hook. The shell agent
provides `CMUX_NEXT_DEV_SCREEN=<conversations|agents|terminal|browser|settings|signin>`
which launches straight into a module root backed by `CNMockHost`. Until it
lands you may add a temporary `#if DEBUG` hook inside your own module only.

## Validation (required)
- Screenshot every screen in light and dark, and look at them.
- For every animation you introduce, record the simulator
  (`remote-ios.sh video` while driving it with `axe`, e.g. `axe swipe ...
  --duration 0.3`), split to frames (`ffmpeg -i in.mp4 -vf fps=60 dir/%04d.png`),
  and compare against the reference recordings under `~/nxios-ref/<app>/`
  with `~/nxios-ref/venv/bin/python -I ios-next/reference/tools/framediff.py`
  (read its `--help`). Iterate until timing (frames to settle, spring fit) and
  geometry match the reference spec within 1 frame / 1 pt.
- Write your evidence summary to `ios-next/reference/validation/<module>.md`
  (tables: element, reference value, measured value, pass/fail) plus a few
  small PNG contact sheets (≤400 KB each). Be honest about anything that does
  not match.
