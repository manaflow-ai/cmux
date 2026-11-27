# iOS terminal

A workspace's terminal: the Ghostty surface, its key bar and the overlays on it. Written from the
code as of this file's commit; a change to the screen updates this file. Rule and detector:
[docs/ios-theme-tokens.md](../../docs/ios-theme-tokens.md).

Code: `WorkspaceDetailView` (Packages/iOS/CmuxMobileShellUI), opened from the workspace list. The
terminal is `GhosttySurfaceRepresentable` over the UIKit `GhosttySurfaceView`
(Packages/iOS/CmuxMobileTerminal); the key bar belongs to the surface (`TerminalInputTextView`),
not SwiftUI. The terminal stays mounted at opacity 0 while a browser, stream or Mac surface is in
front.

App Store reviewer: opens the "App Review" workspace and runs `echo app-review-ok`.

## States

| State | Shows |
| --- | --- |
| No terminal selected | the theme background only |
| Loading | the surface is blank until output arrives; no spinner |
| Live | the grid, keyboard up, key bar on it |
| Reconnecting | nothing covers the grid; the title's dot becomes a spinner and a small "reconnecting" capsule appears; typing still goes out, and a failed send shows a Sending / Send failed pill |
| Disconnected | the last frame stays, touches and the keyboard are off, the title shows a red dot and a subtitle, Reconnect is in the title menu |
| Detached by another device | a card over the surface: Reattach, Reattach as viewer, failure text in red; buttons disabled while it runs |
| Signed into a different account | a pill at the top with Sign Out & Switch Account |
| Couldn't create the terminal | an orange banner above the surface with the message and Retry |
| Size differs from the Mac | the grid letterboxes with a hatched border and a size chip; it doesn't reflow |

Empty and offline have no states of their own beyond the above.

## Selected and foreground

The terminal takes first responder when it attaches to the window and the app is active, so the
keyboard comes up, unless the composer is open. Coming back from another surface refocuses it
unless input is blocked; leaving dismisses the keyboard.

## Zones

- Stable: the grid, the theme-colored ground under the safe areas, the key bar (28 pt row, 8 pt
  above the bottom).
- Dynamic overlays: reconnect capsule, detached card, send pill (top trailing, hidden under the
  composer), account pill, creation banner (pushes content down), letterbox and size chip, zoom
  HUD, artifact and Files chips.

## Device variants

- iPhone: system toolbar. The size it reports to the Mac never drops below the widest width seen
  for the same window size, so the keyboard doesn't reflow the Mac's terminal.
- iPad (regular width): a SwiftUI top bar in place of the navigation bar; reports its current width.
- Foldable iPhone, rotation, keyboard, Stage Manager: any size change refits the grid and reports
  the new columns and rows after an eight-frame settle. Nothing fold-specific.
- Hardware keyboard: key commands through `TerminalHardwareKeyResolver` plus Cmd-V; the key bar
  stays visible.
- Dynamic Type: the grid font is the person's terminal font setting plus pinch zoom; the key bar
  uses fixed sizes and doesn't scale; the size chip follows `.caption2`.
- Dark mode: the chrome follows the terminal theme, not the system. `terminalColorScheme` picks
  light or dark by which text reads better on the theme background, and live theme changes recolor
  in place.

## Tokens

- Theme: `TerminalTheme` (background, foreground, cursor; Monokai by default via
  `MobileTerminalThemeState`), `TerminalTheme+SwiftUI` for readable black or white and contrast.
- Sizing chrome: `TerminalSizingPalette` and `TerminalSizingChromePalette` (contrast floors, mix
  ratios, hatch from `UIColor.separator` in the theme's style).
- Key bar: theme-readable foreground at 72 to 78%, 14% button fill, glass buttons on iOS 26.
- Overlays: `.thinMaterial` / `.ultraThinMaterial`, `.caption2`, `.headline`, `.subheadline`,
  `.secondary`.
- Literals still in the code (baselined): the key bar's `systemFont(ofSize: 14)` and 13 pt symbols,
  the zoom HUD's `UIColor(white: 0, alpha: 0.38)`, the edge-fade mask, the snapshot fallback's
  Monokai `UIColor(red:)` values, the creation banner's `.orange`, the send pill's `.red`, and the
  account pill's black and white.
