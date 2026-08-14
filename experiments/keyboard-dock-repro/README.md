# Keyboard dock reversal repro

This is a UIKit-only reproduction with no cmux terminal, pairing, workspace, or
Ghostty code. Generate the Xcode project with `xcodegen generate`, then build
for an iOS Simulator.

Launch normally for the fixed transaction. Launch with `--buggy` to commit the
composer constraint outside the keyboard animation transaction and reproduce
the snap during rapid up/down toggles.

The fix keeps the dock constraint in the keyboard transition transaction and
uses `.beginFromCurrentState` so reversals continue from the visible position.
