## Summary
- Remove the fixed leading hard-stop overlay from the iOS agent chat shortcut row.
- Let the shortcut scroll region clip naturally next to the attachment/mic controls, preserving the trailing fade only when content overflows.

## Root cause
The row painted a 14pt `systemBackground` rectangle over the leading edge of the scroll view whenever fixed leading controls were present. On top of the keyboard/composer glass material, that solid fill could render as the black vertical block seen between the controls and shortcut row.

## Validation
- `swift test --package-path Packages/iOS/CmuxAgentChatUI`
- `xcodebuild -scheme CmuxAgentChatUI -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/cmux-ios-shortcut-gap-agentchatui build`
- `git diff --check HEAD~1..HEAD`
- localized-string audit, no user-facing strings added
- `/Users/abdulazizalbahar/Dev/Manaflow/cmuxterm-hq/skills/autoreview/scripts/autoreview --mode branch --base origin/main`
- `./scripts/reload.sh --tag sgap`
- `./ios/scripts/reload.sh --tag sgap --simulator cmux-sgap-se-77315 --no-launch --no-setup`
- `./ios/scripts/reload.sh --tag sgap --simulator cmux-sgap-pro-77315 --no-launch --no-setup`
- `xcodebuild test -workspace ios/cmux.xcworkspace -scheme cmux-ios -destination 'platform=iOS Simulator,id=7EAD0EEE-933A-4D17-8F24-B6DD29DFBD1D' -only-testing:cmuxUITests/cmuxUITests/testAgentChatTranscriptKeepsTopEdgeVisibleWithKeyboardAcrossScrollPositions -derivedDataPath /tmp/cmux-ios-sgap-motion -resultBundlePath out/verify-sgap/fresh-motion/xcresult/pro-keyboard-tap.xcresult`

## Evidence
Simulator screenshots and XCUITest attachments were captured from commit `d3caf5bab1`. SE and Pro keyboard-up screenshots show the previously bad region without the black block. The passing tap-based UI test captured bottom/middle/top keyboard-up states after real `ChatComposerField` taps, with metrics moving from `keyboardOverlap=0.0` to `keyboardOverlap=301.0` and `presentationGap=0.0`.

Artifact proof bundle:
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/index.html`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/screenshots/se-keyboard-up.png`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/screenshots/pro-keyboard-up.png`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/screenshots/pro-bottom-keyboard.png`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/screenshots/pro-middle-keyboard.png`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/screenshots/pro-top-keyboard.png`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/media/tap-toggle-overlap-contact-sheet.png`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/metrics/pro-bottom.txt`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/metrics/pro-middle.txt`
- `cmux-assets/fix-ios-shortcut-gap/shortcut-gap-proof/metrics/pro-top.txt`
