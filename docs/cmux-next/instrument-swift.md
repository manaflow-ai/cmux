# Instrument 0.1.0, Swift side

Instrument is cmux's component library. The web half is `webviews/src/kit` (`INSTRUMENT_VERSION`). The
Swift half is the `Instrument` struct in `CmuxNextDesign`
(`Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Instrument.swift`): the web kit's names as `typealias`es
of the native views that already draw them. Version `0.1.0` is the look the app draws today; every name
is an existing type, so using one draws nothing new.

```swift
import CmuxNextDesign

let surface = Instrument.Panel()
let row = Instrument.Row(leading: nil, title: title)
Instrument.version // "0.1.0"
```

## Names

| Web name | Swift name | Swift type | File (under `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/`) |
| --- | --- | --- | --- |
| `Button` (AppKit chrome) | `Instrument.Button` | `ClickableButton` | `ClickableCursor.swift` |
| `Button` (SwiftUI press) | `Instrument.ButtonStyle` | `CmuxPressFillButtonStyle` | `GlassButtonStyle.swift` |
| `Row` | `Instrument.Row` | `PopupRowView` | `Overlay/PopupRowView.swift` |
| `Panel` | `Instrument.Panel` | `CardSurfaceView` | `CardSurfaceView.swift` |
| `Glass` | `Instrument.Glass` | `GlassPanelView` | `GlassPanelView.swift` |
| `GlassLevel` | `Instrument.GlassLevel` | `GlassLevel` | `FloatingGlass/GlassLevel.swift` |
| `GlassMenu` | `Instrument.GlassMenu` | `GlassMenu` | `GlassMenu/GlassMenu.swift` |
| `Tooltip`, `TooltipProvider` | `Instrument.Tooltip` | `TooltipPresenter` | `Tooltip/TooltipPresenter.swift` |
| Motion (`motionToken`, `motionMode`, `springEasing`) | `Instrument.Motion` | `Motion` | `Motion/Motion.swift` |
| `INSTRUMENT_VERSION` | `Instrument.version` | `String` | `Instrument.swift` |

## Not yet in Swift

These web names have no public Swift view that draws the same thing, so the Swift side leaves them out
rather than naming a different view:

- `Card` (the web's anchored glass hover card): the native hover card, `HoverCardPanel`, is internal to
  `CmuxNextDesign`.
- `Menu` and its rows: native right-click menus are the system `NSMenu`; cmux's own drawn menu is `GlassMenu`.
- `Pill`: `ConnectionChip` and `ShortcutHintChipView` are single-purpose chips, not the toned capsule.
- `List`, `Avatar`, `Field`, `Input`, `Popover`, `PopoverButton`, `Icon`, `StatusGlyph`, `Spinner`,
  `SessionList`, `MinimalSessions` and the token helpers.

## Changelog

### 0.1.0

- The Swift names above, over the existing views. No view, look or call site changed.
