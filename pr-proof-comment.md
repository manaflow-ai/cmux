Artifact proof added for the keyboard shortcut-row block fix.

Local proof bundle:
`cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/index.html`

Included evidence:
- SE and Pro keyboard-up screenshots show the previous black-block region removed.
- Passing tap-based XCUITest captured bottom, middle, and top scroll positions after real `ChatComposerField` taps.
- Metrics for all three positions show `keyboardOverlap=301.0`, `composerPresentationMinY=449.0`, and `presentationGap=0.0`.
- Tap-toggle contact sheet shows before, keyboard-up, and typed states around the affected composer row.

The proof is from commit `d3caf5bab1`, tag `sgap`, isolated simulator bundle `dev.cmux.ios.sgap`.
