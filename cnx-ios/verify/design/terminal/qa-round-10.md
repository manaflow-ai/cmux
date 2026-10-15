# Terminal QA round 10 (termqa implementer, 2026-10-15 09:50 PT onward)

Input: qa-round-9.md (`91accfc8`). The shared rig (`cnx-e2e-604fc689` on mini-2, simulator `cnx-termqa-1`)
belongs to a fresh verifier: not touched. Laptop load 20-30 at the start: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| G-14 TUI selection (vim, htop): a long press always selects | **implemented**: test `29260240` (red: type missing), fix `fd2e3c3a` (green: 15 of 15 with the selection and autoscroll suites, mini-cmux11s); iOS build green (`1769b3bf`, tag tq10). **Not run on the simulator yet** | below |
| Hidden laptop rig (real Codex) | in progress | Rig |
| G-17 with real Codex (1259, 1337, 1350-b) | not run yet | |
| G-14 autoscroll / full-scrollback copy on the simulator | not run yet | |
| D6, V6-5, D10, V2-6, 60-min sessions, D7 | not run yet | |

## Rig (hidden laptop rig, tag tq10)

- Mac: a fleet build of `e1edf234` (the rig app's daemon) with its own tag `tq10-e1edf234`
  (bundle `com.cmuxterm.app.debug.tq10.e1edf234`, own dev-backend stack). Fleet job
  `4faa3b2ec5167d9b355aae07`, in `~/cnx-ios-builds/20261015-e1edf23408-tq10`. The app is used as built:
  its Info.plist is never edited and it is never re-signed. `TQ_HOST=local` (`tq.LocalMac`) launches it
  with `open -g -j -n --env ...` for every setting (shell integration, bundled CLI, daemon socket, config
  file, credential file, pairing seed). `open --env` overrides LSEnvironment (checked with a test bundle).
- Phone: simulator `cnx-tq10` (070F8E62…), headless (`simctl boot`; Simulator.app never opened). New build:
  Demo `1769b3bf`, tag tq10, bundle `dev.cmux.cnx.tq10`.
- Select: `TQ_HOST=local TQ_RBASE=~/cnx-ios-e2e/tq10 TQ_STATE=~/cnx-ios-e2e/tq10-state.json
  TQ_RAW=~/cnx-ios-e2e/termqa-raw/tq10 TQ_BUNDLE=dev.cmux.cnx.tq10`.
- Codex: the laptop's existing login, used as is.
- `cnx-ios/scripts/demo-build.sh`: the simulator build is now `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.

## G-14: TUI selection

`TerminalSelectionController` now takes any host view (the scroll view or the TUI host); edge autoscroll
runs only in a scroll view. The view controller keeps a second controller, `tuiSelection`, in `tuiHost`:
`TerminalTUISelectionGeometry` maps a point to a viewport cell (row 0 = the top row, clamped to the grid)
and back; the text comes from `viewportText`; Select All is the whole screen. The shell's selection is
cleared when a TUI starts, the TUI's when it ends; a tap clears either. The phone never forwards touches
as mouse events, so a long press always selects, like Shift-drag on the Mac when the app captures the
mouse (htop, vim `mouse=a`).

## Next

(updated as the round goes)
