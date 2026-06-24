# cmux launch smoke recording

## Repro steps attempted
1. Ran:
   - `./scripts/reload.sh --tag recsmk --launch`
2. Captured app path from output:
   - `/Users/runner/Library/Developer/Xcode/DerivedData/cmux-recsmk/Build/Products/Debug/cmux DEV recsmk.app`
3. Ran:
   - `./.cmux-loader/approve-computer-use-app "/Users/runner/Library/Developer/Xcode/DerivedData/cmux-recsmk/Build/Products/Debug/cmux DEV recsmk.app"`
4. Ran:
   - `./.cmux-loader/set-app-window-frame "cmux DEV recsmk" 20 90 1500 950 2`
5. Ran:
   - `./.cmux-loader/record-video start repro 180`
6. Used computer-use to bring the tagged app frontmost and type in the terminal:
   - `echo cmux cloud recording smoke OK`
7. Ran:
   - `./.cmux-loader/record-video stop repro`

## Results
- Did cmux launch? **Yes**.
- Did computer-use interact with cmux? **Yes**.
- Video artifact name: **repro**
- Video path: `/Users/runner/work/cmux-loader/cmux-loader/.runner/videos/repro.mov`

## Environment notes / blockers
- `AppleShowScrollBars` was unset (checked by default workflow notes).
- `approve-computer-use-app` completed with `== done ==` and added `com.cmuxterm.app.debug.recsmk` approval.
- No blocking issues for this task.
