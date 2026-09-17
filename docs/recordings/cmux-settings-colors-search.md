# cmux settings colors search recording

## Task
Recording-only for settings search in colors.

## Exact steps attempted
1. Ran `./scripts/reload.sh --tag setclr --launch`.
2. App path from reload output: `/Users/runner/Library/Developer/Xcode/DerivedData/cmux-setclr/Build/Products/Debug/cmux DEV setclr.app`.
3. Ran `./.cmux-loader/approve-computer-use-app "/Users/runner/Library/Developer/Xcode/DerivedData/cmux-setclr/Build/Products/Debug/cmux DEV setclr.app"`.
4. Ran `./.cmux-loader/set-app-window-frame "cmux DEV setclr" 20 90 1500 950 2`.
5. Ran `rm -f ../.runner/target-window-id`.
6. Ran `./.cmux-loader/record-video start repro 180`.
7. Used computer-use in `cmux DEV setclr` and pressed the standard settings shortcut `⌘,`.
8. Settings opened in-app (`Window: Settings`, app `cmux DEV setclr`).
9. Focused search field and typed exactly `colors`.
10. Kept the search field and visible results onscreen for ~3 seconds.
11. Ran `./.cmux-loader/record-video stop repro`.

## Outcome
- Settings opened: `yes`.
- Search field accepted `colors`: `yes` (search field value became `colors` and results list updated).

## Video artifact
- `repro`

## Environment notes / blockers
- No blockers encountered during recording.
- approval output for computer-use was verbose but succeeded with `approved_computer_use_app`.
- macOS scroll-bar setting check from this run: `AppleShowScrollBars=unset`.
