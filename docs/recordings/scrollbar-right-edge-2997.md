# scrollbar-right-edge-2997

- Task source URL: https://github.com/manaflow-ai/cmux/issues/2997
- Recorded artifact: `repro`
- Date: 2026-05-01
- Host user-visible note: recording-only task

## Environment notes
- Scrollbar setting before launch: `defaults write -g AppleShowScrollBars -string Always` (confirmed by `defaults read -g AppleShowScrollBars`).
- App launch/tag: `./scripts/reload.sh --tag scr2997 --launch`
- App path used: `/Users/runner/Library/Developer/Xcode/DerivedData/cmux-scr2997/Build/Products/Debug/cmux DEV scr2997.app`
- Approved app for computer-use with `./.cmux-loader/approve-computer-use-app`.
- App window set via `./.cmux-loader/set-app-window-frame "cmux DEV scr2997" 20 90 1500 950 2`

## Repro steps attempted
1. Build and launch tagged app `scr2997`.
2. Approve app for computer-use controller and position window with helper script.
3. Preflight recording:
   - `./.cmux-loader/record-video start preflight 10`
   - moved pointer over terminal window and waited at least 4 seconds
   - `./.cmux-loader/record-video stop preflight`
4. Repro recording:
   - `./.cmux-loader/record-video start repro 30`
   - Focused terminal pane (text entry area).
   - Executed Python generator:
     - `python3 - <<'PY'`
     - `import shutil`
     - `cols = max(shutil.get_terminal_size().columns, 80)`
     - `pattern = "1234567890"`
     - `line = (pattern * ((cols // len(pattern)) + 2))[:cols]`
     - `for i in range(180):`
     - `    print(line)`
     - `PY`
   - Waited for output to accumulate with long right-edge marker lines.
   - Ensured vertical scrollbar visible on terminal right side.
   - Hovered pointer near terminal right edge for at least 2 seconds.
   - Kept final pane state visible until capture duration elapsed.
   - `./.cmux-loader/record-video stop repro`

## In-video milestones to verify
- `cmux DEV scr2997` terminal pane visible with generated multi-line numeric output.
- Right-side terminal scrollbar shown in the terminal content area.
- Pointer visible near right edge of terminal.
- Final recorded state left visible for the remainder of the clip.

## Result
- Reproduction artifact captured successfully as `repro`.
- `preflight` and `repro` stop logs reported `status=ok`.
- `repro.log` did not report `primary recording missing`.
- Manual interpretation of the screenshot-based artifact was not performed during this run; review is required to confirm exact amount of rightmost-text obstruction.

## Blockers
- None during recording workflow.
