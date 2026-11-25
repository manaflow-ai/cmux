# iOS onboarding (first run)

The tour shown once after the first sign-in, ending in finding the person's Mac. Written from the
code as of this file's commit; a change to the screen updates this file. Rule and detector:
[docs/ios-theme-tokens.md](../../docs/ios-theme-tokens.md).

Code: `OnboardingFlowView` (Packages/iOS/CmuxMobileShellUI), chosen by `CMUXMobileRootView` when
`MobileOnboardingProgress.shouldShowOnboarding` holds (signed in, not restoring, progress not
`.complete`). Progress persists in `MobileOnboardingStore`. The Cloud tab's `CloudOnboardingView`
is a separate intro that borrows this look.

App Store reviewer: signs in with the demo account, then walks these pages. The demo account's
local "Demo Mac" stands in for a live Mac on the connect page (`OnboardingDemonstrationAccountPolicy`).

## Pages and states

One horizontal pager, swipeable: agents, notifications, push, pairing, connect. A person who left
during connect resumes at connect.

| Page | Shows | Actions |
| --- | --- | --- |
| Agents | "Your agents keep working on your Mac" | Continue, Skip |
| Notifications | "Every agent alert, in one place" | Continue, Skip |
| Push | "Know the moment an agent needs you" | Enable Notifications (system alert; double taps blocked until it resolves), Not Now, Skip |
| Pairing | "Enable iOS pairing on your Mac", "Required for Mac discovery" note, two steps | "I've enabled iOS pairing" (no Skip) |
| Connect | connection method picker, preview card, Keep Mac Awake card once ready | by phase, below |

Connect phases:

| Phase | Status line | Primary |
| --- | --- | --- |
| idle | "Ready to look for your Mac" | Check for My Mac (Tailscale: Scan Pairing Code) |
| searching | spinner, "Looking for your Mac…" | none |
| fallback (failed) | "Couldn't connect to your Mac yet" | Check Again (Tailscale adds Scan Pairing Code) |
| ready | "Connected securely" | Open Workspaces |

Loading: none; pages are static. Empty: none. Error: only the connect fallback phase; there is no
error banner. Offline: no separate state; connect stays in fallback. Signed out: the flow never
shows (sign-in comes first). A too-old Mac: the connect copy names the minimum Mac version when known.

## Selected and foreground

The footer's primary button is the one prominent control; there is no text field. Back is hidden
on the first page. The sheet can't be swiped away (`interactiveDismissDisabled`).

## Zones

- Stable: the Game of Life backdrop, the header (Back, Skip, page dots; empty slots hold their
  place), and the footer, whose secondary slot stays reserved in regular height so the primary
  button doesn't move.
- Dynamic: page content, the connect status line and card, footer titles. Body copy reserves two
  lines (three on pairing and connect) so the visual above it doesn't shift.

## Device variants

- iPhone portrait: stacked layout, copy at most 560 pt, visual at most 520 pt.
- iPad, and any regular-width window: side-by-side layout (copy 390 pt, visual 520 pt, 980 pt cap),
  except at accessibility text sizes, which stay stacked.
- Foldable iPhone: layout follows size class only, so folded is the iPhone layout and unfolded is
  side by side only if the system reports regular width. Nothing reads the raw width.
- Rotation (compact height): side-by-side copy (280 pt), footer buttons in a row, the connect
  visual horizontal; `ViewThatFits` falls back to the compact card density.
- Dynamic Type: text styles throughout, visuals capped at `xxxLarge`, the screenshot frame shrinks
  at accessibility sizes. No `@ScaledMetric`.
- Dark mode: semantic colors, scheme-aware backdrop and light/dark screenshot assets.
- Reduce Motion: pager, dots and the root transition fall back to fades.

## Tokens

- Backdrop: `PlatformPalette.systemBackground`, `PlatformPalette.gameOfLifeCell(colorScheme:)`.
- Text: `.largeTitle` bold `label` titles, `.body` `secondaryLabel` bodies, `.subheadline` controls.
- Accent: `Color.accentColor` (active page dot, selected method), `.tint` step icons.
- Buttons: `mobileGlassProminentButton()` / `mobileGlassButton()` (glass on iOS 26, bordered before).
- Cards: `.regularMaterial` with a `Color.primary.opacity(0.08)` edge.
- Literals still in the code (baselined): the pairing note's `.orange` fill and the ready status
  `.green` (`OnboardingPairingView`, `OnboardingConnectionPreview`), the device circles' `.indigo`
  and `.blue`, and the per-density radius and padding tables in the connect cards. There is no
  shared status-color token yet.
