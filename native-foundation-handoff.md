# Native popup foundation handoff

- Repository/worktree: `/home/leo/Projects/checkouts/cmux/nx-native-popup-foundation-1028`
- Branch: `nx-native-popup-foundation-1028`
- Live base at last rebase: `fe31ba94c5d1eeee3c81dc1768a8a910872e9b8c`
- Pushed exact head: `3af18008b76c22ea4a4db0379df3da5a40e5d99a`
- PR: #27142
- Dirty edits: none after push/rebase; worktree was clean before this handoff note was created.

## Verification

- `python3 scripts/cmux-next/prepush-gate.py --base origin/feat-cmux-next --head HEAD --only scanners,ast-grep,swiftformat,swiftlint,reserved,conflicts,crash-allow,freeze`: passed (`no new violations`).
- `(cd webviews && bun test src/ui/nativePopup.test.ts)`: 1 pass, 0 fail, 5 expectations.
- `cmux-ci compile-check --ref 3af18008b76c22ea4a4db0379df3da5a40e5d99a --package CmuxNext --no-cmux-tui --recipe-version 2 --timeout 3600`: job `853d1eedba8b1a41affd9095`, passed in 259 seconds.
- Supported Astra HIGH review, exact pair `fe31ba94c5d1eeee3c81dc1768a8a910872e9b8c..3af18008b76c22ea4a4db0379df3da5a40e5d99a`, lane `gcp-codex-lane-2/popup-foundation-review-27142-r2`, session `01a18581-cf98-7153-b8eb-d11750049e76`: terminal `BLOCK`.

## Review finding requiring owner fix

Astra BLOCK P2: `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Overlay/DeclarativePopupHost.swift:84-87,170-188` shows submenus with `makeKey: false`. The submenu uses a `NativePopupPanel` and native keyboard/escape/focus handling, but does not become key, so keyboard navigation/typeahead/text input can remain with the parent/content window. Review says submenu native behavior is unreachable for keyboard interaction. Root must inspect `NativePopupHost.show`/`NativePopupPanel` focus contract and make child popup key/focus ownership explicit while preserving parent restoration and instant-open behavior. Do not silently mark SHIP.

## Prior repaired findings already included in 3af head

1. `DeclarativePopupHost.hide(id:revision:)` now checks current identity/revision before creating a tombstone; stale hide cannot block a later show.
2. `NativePopupContent.update` refreshes search value, placeholder, and enabled state even when stable search ID is unchanged.

## Outstanding external state

- Native glass capture/readability witness still outstanding; no private user screenshot in PR.
- External Swift HOLD #26809 remains reported by coordinator; do not bypass it.
- Do not start duplicate compile/review jobs. Root should fix the submenu focus finding, rebase if base moves, push a new head, rerun focused native fleet compile and one exact-head Astra review, then stop ready-or-block.
