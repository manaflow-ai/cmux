# cmux Settings Colors Search Recording

## Task
- Task: recording-cmux-settings-colors-search-7
- Branch/tag: `setclr7`
- Date: 2026-04-30

## Steps Attempted
1. Built and launched tagged app:
   - `./scripts/reload.sh --tag setclr7 --launch`
   - App path: `/Users/runner/Library/Developer/Xcode/DerivedData/cmux-setclr7/Build/Products/Debug/cmux DEV setclr7.app`
2. Approved computer-use access:
   - `./.cmux-loader/approve-computer-use-app "/Users/runner/Library/Developer/Xcode/DerivedData/cmux-setclr7/Build/Products/Debug/cmux DEV setclr7.app"`
3. Sized app window:
   - `./.cmux-loader/set-app-window-frame "cmux DEV setclr7" 20 90 1500 950 2`
4. Cleared target window IDs before preflight:
   - `rm -f "$CMUX_LOADER_RUNNER_DIR/target-window-id" ../.runner/target-window-id .runner/target-window-id`
   - Verified absent with `test ! -f "$CMUX_LOADER_RUNNER_DIR/target-window-id"`
5. Started and completed preflight capture:
   - `./.cmux-loader/record-video start preflight 8`
   - Used computer-use to keep pointer over cmux window during bounded interval.
   - `while ./.cmux-loader/record-video status | grep -q "running name=preflight"; do sleep 1; done`
   - `./.cmux-loader/record-video stop preflight`
6. Cleared target window IDs again before repro:
   - same `rm -f ...` command and check
7. Started and completed repro capture:
   - `./.cmux-loader/record-video start repro 30`
   - Brought `cmux DEV setclr7` frontmost, opened Settings with `Cmd-,` via computer-use.
   - Focused search field in Settings and typed exactly `colors`.
   - Left Settings visible until recording elapsed.
   - `while ./.cmux-loader/record-video status | grep -q "running name=repro"; do sleep 1; done`
   - `./.cmux-loader/record-video stop repro`

## Verification
- Preflight primary recording log check:
  - `../.runner/videos/preflight.log` did not contain `primary recording missing`.
  - Result: preflight succeeded.
- Repro primary recording log check:
  - `../.runner/videos/repro.log` did not contain `primary recording missing`.
  - Result: repro succeeded.

## Outcomes
- Settings opened via `Cmd-,`: **Yes**
- Search field accepted `colors`: **Yes** (field value showed `colors` in Settings search)

## Video Artifacts
- `preflight` → `preflight.mov`
- `repro` → `repro.mov`

## Blockers / Environment Notes
- No recording blockers encountered.
- Runner scrollbar context from loader info: `AppleShowScrollBars=unset` / `NSGlobalDomain AppleShowScrollBars=unset`.
