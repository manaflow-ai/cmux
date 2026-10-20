# Full app verification (fresh verifier), 2026-10-19

Status: IN PROGRESS. Partial results are pushed as they land.

Lane: everything except the terminal, tab UX and transports (onboarding and
account, Home, Workspaces, Feed, Chief, agent chat, files and diffs, Settings,
Mac parity).

## Build under test

- Phone: `3e6a2b56eff` (the cmux INTERNAL 1.2.0 commit), Demo configuration,
  `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, bundle `dev.cmux.cnx` 1.2.0 (1), dev
  Worker `cnx-ios-api-dev.debussy.workers.dev`. Built with Xcode 26.6 on
  mini-cmux7s (Xcode 26.3 on mini-2 fails at
  `CmuxTabsKit/UI/Toolbar.swift:391: ambiguous use of operator '-'`), then
  copied to mini-2. CnxFFI.xcframework from the rig cache, key
  `ccc2097337090383` (the sha1 of this commit's `cnx-ios/rust`,
  `cmux-wg`, `cmux-transport` trees).
- One headless simulator `cnx-fv-1` (iPhone 17 Pro, iOS 26.3, the only
  runtime on mini-2) on `mini-cmuxs-mac-mini-2`. Simulator.app is never
  opened by this run.
- Mac: fleet build `cnx-e2e-90375ce5` (job `b65d313ac0f91b52bbb59726`). It
  is the Mac half of this commit: `git diff 90375ce5e1 3e6a2b56eff` touches
  only `cnx-ios/CnxKit/Sources/CnxShell/RootView.swift` (phone),
  `cnx-ios/scripts/testflight-build.sh` and the TestFlight workflow, so the
  Mac app, cnx-hostd, daemon and acpmux sources are identical. An unmodified
  copy runs hidden (`open -g -j -n`) on mini-2; every setting goes in with
  `open --env` (`verify/parity/rmac.py`). Device id `1d1915d9…e14e`, shown
  on the phone as "cmux’s Mac mini (2) E14E".
- Account: the DEBUG dev credential (email step "42").
- Driver: `verify/fullverify/fv.py` on the mini (AXe HID taps, typed
  text); `fvr.sh` runs it from the laptop. Mac CLI only reads state.

Evidence (git-ignored): `verify/evidence/2026-10-19/full-verify-app/`
(`shots/*.png`, `video/*.mp4`), mirrored from `~/cnx-fv/evidence` on mini-2.

## Results
