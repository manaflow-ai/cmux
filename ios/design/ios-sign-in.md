# iOS sign-in

The first screen for a signed-out person. Written from the code as of this file's commit; a change
to the screen updates this file. Rule and detector: [docs/ios-theme-tokens.md](../../docs/ios-theme-tokens.md).

Code: `SignInView` (Packages/iOS/CmuxMobileShellUI), shown by `CMUXMobileRootView` when
`MobileRootAuthGate.shouldShowSignIn` holds: signed out, or a saved session still restoring while
first-run onboarding is unfinished. An attach ticket never shows it.

App Store reviewer: the demo account is an email-code account (no password). The reviewer taps
"Email me a code", reads the code from the public inbox named in the review notes, and enters it.
Apple, Google and GitHub sign-in are also offered.

## States

| State | Shows |
| --- | --- |
| Signed out (methods) | the cmux mark and name; Apple, Google, GitHub buttons; "or continue with email"; the email field; "Email me a code" (disabled while the email is blank) |
| Code | "Check your email", "We sent a code to …" (middle-truncated), a six-character code field that verifies itself when full, Verify code, Use a different email |
| Email verification | "Verify your email", I verified my email, Use a different email; resend and billing recovery appear after an unverified-email error |
| Restoring a saved session | under the mark: a spinner, "Restoring session", inputs disabled. After 10 s: a warning icon, "Still restoring session", Retry |
| Working (any request) | the card dims to 60% and its buttons disable; the tapped button shows a spinner at its own size. No cancel |
| Error | one line of caption text under the controls, selectable, from `SignInErrorPresentation` (bad email or code, expired code, rate limit, browser sign-in failed) |
| Offline | no separate view: "Could not connect to the server. Check your internet connection and try again." as the error line, or the restore timeout |
| Cancelled OAuth | no error |

Loading and empty states don't apply beyond the restore row.

## Selected and foreground

Nothing is focused on arrival, so the keyboard stays down. The OAuth buttons lead; "Email me a
code" is the one prominent button. The code field takes focus only if the email field had it when
the code was sent. Tapping outside the card dismisses the keyboard.

## Zones

- Stable: the full-screen backdrop, the bottom-anchored card, the mark and name (identical in
  every mode).
- Dynamic: the card's content swaps between the three modes (`.snappy`, 0.18 s); the restore row,
  error line, billing recovery block and button spinners appear inside it.

## Device variants

- iPhone: the card fills the width at the bottom, 20 pt side padding.
- iPad, foldable iPhone unfolded, any wide window: the card stays at most 430 pt wide, centered at
  the bottom, and the backdrop fills the rest. No size-class or width logic beyond that cap.
- Rotation: no special layout; the same capped card.
- Dynamic Type: text styles scale. The code field is a fixed 32 pt monospaced font on a fixed 60 pt
  pill and the email pill is fixed at 50 pt; the standalone card doesn't scroll, so accessibility
  sizes can push it past the bottom.
- Dark mode: semantic colors; only the backdrop reads the color scheme.
- iOS 26: glass buttons and pills in a `GlassEffectContainer`; bordered and `.thinMaterial` before.

## Tokens

- Backdrop: `PlatformPalette.systemBackground`, `PlatformPalette.gameOfLifeCell`; divider lines
  `PlatformPalette.separator`.
- Text: `.title2` semibold name, `.headline`, `.subheadline`, `.caption`; `.primary` and `.secondary`.
- Buttons and fields: `mobileGlassButton()`, `mobileGlassProminentButton()`, `GlassInputPill`.
- Literals still in the code (baselined): the error line's `.red`, the restore warning's `.orange`,
  and the code field's `.system(size: 32, design: .monospaced)`.
