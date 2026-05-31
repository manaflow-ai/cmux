# Aurean appearance

Aurean is cmux's golden-ratio (φ) based appearance system. It dresses the whole app —
the terminal canvas and the window chrome (sidebar, titlebar, backdrop) — in one cohesive
dark palette, and lets you switch the palette *temperature* live from Settings.

## Using it

Open **Settings → App → Palette** and pick a temperature:

| Variant | Negative space | Notes |
| :-- | :-- | :-- |
| **Cool** | blue-grey | the cmux default |
| **Dune** | warm sand | the canonical Aurean Protocol base |
| **Warm** | amber | warmest negative space |
| **Obsidian** | cold near-black | maximum contrast |

The choice is persisted and re-skins the running app immediately — no relaunch. Every
variant keeps the same **signal** colors so muscle memory survives: gold for
needs-input/dirty (`warn`) and rust for failure/destructive (`crit`) never move; only the
negative space, the sand text, and the accent/ok signals shift with temperature.

**Light mode.** Aurean is a dark-first design with no light variant. In light appearance
mode it stands down: the app keeps your existing Ghostty/system colors, opacity, and
sidebar material, and the accent falls back to the original cmux blue. Aurean drives the
surfaces only in dark mode.

**Terminal transparency.** Aurean owns the window backdrop as an opaque surface, so a
translucent terminal composites over the palette canvas instead of the desktop wallpaper.
Your terminal's own background opacity is preserved.

## Architecture

The color system lives in the leaf Swift package **`Packages/CmuxAppearance`** (no
dependencies; unit-tested without launching the app):

- `AureanColor` — a resolution-independent sRGB color value (hex parsing, the φ-opacity
  ladder, `Color`/`NSColor` bridges). Storage is plain components, so the whole layer is
  testable without AppKit.
- `AppearancePalette` — the protocol of eight semantic roles
  (`surfacePrimary`/`surfaceOff`/`surfaceAbyssal`, `text`, `accent`/`ok`/`warn`/`crit`).
- `AureanPalette` / `AureanPaletteVariant` — the concrete token values per temperature.
  `AureanPaletteVariant.userDefaultsKey` is the single persisted key, and `.palette`
  returns a shared cached value (cheap to read on hot paths).
- `AureanMetrics` — φ, the Fibonacci spacing ladder, the type scale, and the golden split.
- `AureanTheme` — an `@Observable @MainActor` owner of the active variant, injected at the
  app root via `View.aureanTheme(_:)` and read through `@Environment(\.aureanPalette)`.

### How it reaches the app

The app target adopts the package at three seams:

1. **Root injection** — `cmuxApp` constructs `AureanTheme` (seeded from the persisted
   variant) and injects it; SwiftUI chrome reads `@Environment(\.aureanPalette)`.
2. **Ambient AppKit** — chrome rendered outside SwiftUI (accent, window/sidebar backdrops)
   reads `AureanAppearanceSettings` (`Sources/Sidebar/SidebarAppearanceSupport.swift`),
   which resolves the active palette from the same `UserDefaults` key. The window chrome
   mirrors the terminal background, so driving the canvas re-skins the chrome with it.
3. **Live switch** — changing the variant updates the SwiftUI theme owner and calls
   `GhosttyApp.reapplyAureanSurface()`, which forces the canvas (and the chrome that
   mirrors it) to re-resolve from the new surface.

The override is a runtime, in-app behavior — it does **not** write your `~/.config/ghostty`.

## Adding a palette role or variant

Add the case to `AureanPaletteVariant`, fill its token values in `AureanPalette`, and the
picker (`AureanPalettePickerRow`) and tests pick it up from `allCases`. Keep `warn`/`crit`
identical across variants — that invariant is asserted by `AureanPaletteTests`.
