# Mobile Safari reference spec (iOS 27, iPhone 17 Pro)

Measured reference for rebuilding a streamed-browser viewer that matches Mobile
Safari's layout, materials, and motion 1:1.

- Device: iPhone 17 Pro simulator, iOS 27.0, 402 × 874 pt, @3x (1206 × 2622 px).
- Default settings: compact "bottom" layout (`View=Narrow`, `UsingLoweredBar=true`
  in Safari's accessibility identifiers), no tab bar.
- Method: the simulator was driven with AXe, frames were measured from
  `simctl` screenshots, and per-frame geometry was taken from `recordVideo` H.264
  captures at their passthrough timestamps. The accessibility tree supplied exact
  frames for the controls. Pixel measurements are ±0.33 pt (1 px). Spring fits
  use SwiftUI's `spring(response:dampingFraction:)` model; see
  [Animation timing](#8-animation-timing).
- Test pages: a plain white page with 300 px rows (`plain.html`), a solid
  `#e01b24` page (`red.html`), and a chunked slow page, served on localhost. Real
  pages: en.wikipedia.org/wiki/Terminal_emulator, github.com/ghostty-org/ghostty,
  and a Google search.
- All coordinates are in points, with the origin at the top-left of the screen.
  Images are in `reference/safari/`. Sheet images use a yellow tag to show the
  frame number and the time from the first frame of the sheet.

---

## 1. Screen anatomy (compact layout, page loaded, at the top of the page)

```
y=0   ┌──────────────────────────────────────────┐
      │ 10:33            (island)         ⋯ 📶 ▭ │  status bar, no chrome
y=62  │------------ safe-area top --------------│  web content inset.top = 62
      │                                          │
      │            web content (full screen,     │  WKWebView frame = 0,0 402×874
      │            scrolls under the status bar  │
      │            and the toolbar)              │
      │                                          │
y=792 │   ( ‹ )  (  ≡   en.wikipedia.org   ↻ ) ( ⧉ ) │  floating glass controls
y=840 │   34 48 8      222 pt capsule       8 48 34  │
      │                                          │
y=874 └──────────────────────────────────────────┘  34 pt below (home indicator zone)
```

There is no top navigation bar. The web view fills the screen. The top content
inset is 62 pt, which is the status-bar safe area. The area above the content
shows the page background color (see [section 7](#7-status-bar-and-top-safe-area)).

## 2. Bottom toolbar (expanded)

### 2.1 Geometry (from the accessibility tree, verified against pixels)

| Element | Frame (x, y, w, h) | Notes |
|---|---|---|
| Back button | 34, 792, 48 × 48 | Separate glass circle. `BackButton` |
| Address capsule | 90, 792, 222 × 48 | Glass capsule, corner radius 24. `CapsuleNavigationBar` |
| └ Page menu button | 90, 792, 48 × 48 | Leading hit area inside the capsule. `MoreMenuButton` |
| └ Page menu glyph | 106.7–122.7 × 810–821.7 | 16 × 12 pt |
| └ URL label | 140 → 267 (text field). Text is centered on x = 201 | `TabBarItemTitle`, field height 20.3 |
| └ Reload / stop glyph | 281.3, 805.7, 17.7 × 21 | Ink is 14.7 × 18 pt |
| Tabs button | 320, 792, 48 × 48 | Separate glass circle. `TabOverviewButton` |
| Tabs glyph ink | 332.3–355 × 805–827 | 23 × 22 pt |

- Side insets are 34 pt on the left and right. The gaps between the circles and the capsule are 8 pt.
- The bottom inset from the bar's bottom edge to the screen bottom is 34 pt. The bar's vertical center is at y = 816.
- Hit targets are the full 48 × 48 circles. Inside the capsule, the hit target is the 48 pt leading slot.

Reference images: `toolbar-expanded-light.png`, `toolbar-expanded-dark.png`, and
`toolbar-capsule-zoom-3x.png` (native 3× pixels).

### 2.2 Content and typography

| Item | Spec |
|---|---|
| URL text | SF Pro **17 pt**. Line height 20.3 matches the 17 pt field. The cap and ascender height of "l" is 12.7 pt. The stem is about 1.7 pt thick, which reads as **Medium** weight. Color `#000000` in light mode and `#FFFFFF` in dark mode. |
| Domain display | Shows the registrable host only: `en.wikipedia.org`, `github.com`, or `localhost`. There is no scheme, path, `www.`, or lock icon. Secure pages are flagged by `IsSecure=true` in the window identifier, but nothing visible marks them. |
| Search results | Shows the query with a leading magnifying glass, for example `🔍 terminal`, and a mic button where reload would be. |
| Empty, new tab | Placeholder "Search or enter website" in secondary label color, with a leading `magnifyingglass` and a trailing `mic` (Voice Search). |
| Text alignment | Centered on the screen at x = 201. The capsule is also centered. |

### 2.3 SF Symbols (identifiers taken from the accessibility tree where Safari exposed them)

| Control | Symbol | Size |
|---|---|---|
| Back | `chevron.left` (medium weight) | Ink about 9 × 17 pt. Disabled color `#C5C5C7` (light) / `#5B5B5D` (dark) |
| Page menu | Three left-aligned lines of decreasing length; the closest match is `text.alignleft` | 16 × 12 pt |
| Reload | `arrow.clockwise` | 14.7 × 18 pt ink |
| Stop (while loading) | `xmark` | Same slot |
| Tabs | `square.on.square` | 23 × 22 pt |
| Voice search | `mic` | 17 × 21 pt |
| Clear text (editing) | `xmark.circle.fill` | In a 44 × 48 slot |
| Close editing | `xmark` in a 48 pt glass circle | |
| Start-page segments | `square.grid.3x3.fill`, `book`, `eyeglasses`, `clock` (`magnifyingglass` replaces the grid icon while editing) | 20–31 pt wide |

### 2.4 Glass material ("Liquid Glass")

The back button, the capsule, and the tabs button are three separate glass
shapes. They merge and morph together during transitions (sections 4–6).

| Token | Light | Dark |
|---|---|---|
| Fill over pure white (`#FFF`) | `#F9F9F9`–`#FDFDFD` (center), `#FCFCFC` near the bottom | n/a |
| Fill over pure black (`#000`) | n/a | `#1F1F1F`–`#202020` (about white at 12%) |
| Fill over `#E01B24` red | `#FF7E87` (about white at 44% plus a saturation boost) | n/a |
| Rim, outer pixel | `#B0B0B0` 1 px (0.33 pt), then `#D7D7D7` | Specular gradient: `#5A5A5A` at the top and bottom edges, `#494949`, `#3B3B3B`, fading to fill within 1 pt |
| Top highlight | `#E5E5E5` → `#D9D9D9` along the top 1 pt | Same gradient as the rim |
| Shadow | Very soft and wide. Below the bar, `#FCFCFC` → `#FFFFFF` over about 10 pt; above it is barely visible. Roughly `y 4, blur 16, black 6–8%` | Not visible on black |
| Content behind | Refracted and blurred (see `toolbar-glass-over-content-light.png`): a strong blur (about 10–15 pt) plus lensing at the edges | Same |
| Glyph color | Label `#000` (95%). Disabled glyphs use tertiary gray | `#FFF` |

Implementation: on iOS 26+, use `.glassEffect(.regular, in: .capsule)` for the
capsule and `.glassEffect(.regular.interactive(), in: .circle)` for the buttons,
inside one `GlassEffectContainer(spacing: 8)` so that they merge. Below iOS 26,
approximate the effect with `UIBlurEffect(.systemUltraThinMaterial)`, a
`white @ 0.45` overlay, a 0.33 pt rim at `black @ 0.25`, and the soft shadow.

### 2.5 Progress bar

| Property | Value |
|---|---|
| Position | Inside the capsule along its **bottom edge**, clipped to the capsule shape. It is visible from x ≈ 104 (the start of the capsule's curve) to the right. |
| Thickness | 2 pt (y 837.3–839.3, flush with the capsule bottom at 840) |
| Color | `#0088FF` (iOS 26+ `systemBlue`), the same in both modes |
| Behavior | It jumps to about 3% (w ≈ 3 pt) when navigation commits, then eases to about 8 pt over roughly 250 ms (asymptotic trickle) and grows with the real load progress. At completion it fills and fades out. While loading, the reload glyph swaps to `xmark` (stop) with a crossfade. |
| Also | The link-preview sheet shows the same bar under its header (section 6.3). |

Image: `progress-bar-zoom.png`. The bar is the thin blue sliver at the bottom-left
of the capsule, magnified 2× from the 3× source.

## 3. Collapsed toolbar ("mini URL pill")

The pill appears after scrolling down by more than a small threshold, about
10–20 pt of downward drag.

| Element | Value |
|---|---|
| Pill frame | **156.7, 828, 89 × 32** (it hugs the text width: text plus about 19 pt padding per side), centered at x = 201.3 |
| Bottom inset | 874 − 860 = **14 pt** |
| Corner radius | 16 (a capsule) |
| Text | Same label, scaled. Its width goes from 69 to 51 pt (×0.74), so it renders at about **12.5–13 pt** Medium. The text is centered at y = 843.8. |
| Hidden | The back and tabs circles fade out and scale toward the center. The page menu and reload glyphs fade out. The progress bar remains visible at the pill's bottom-left. |
| Material | Same glass as the expanded bar (fill `#F9F9F9` light / `#232323` dark; rim as in 2.4) |
| Tap | Anywhere on the pill expands it (and does **not** scroll the page) |
| Scroll up | Any upward scroll of more than a few points expands it, even mid-page |
| Top of page | Reaching the top of the page expands it |

Images: `toolbar-collapsed-light.png`, `toolbar-collapsed-dark.png`,
`toolbar-collapsed-over-content.png`, and `full-status-bar-red-collapsed.png`.

```
expanded:   ( ‹ )( ≡    en.wikipedia.org    ↻ )( ⧉ )    y 792–840, x 34–368
                         │ spring 0.36 s, ζ≈0.9
collapsed:            ( en.wikipedia.org )               y 828–860, w = text + 38
```

## 4. Scroll-collapse transitions (frame data)

The transitions are **not scroll-linked**. Once the threshold is crossed, a
time-based spring runs to completion while the page keeps scrolling. Tracked
values: the capsule's top-edge y, the URL text width, and the visible ink of the
side buttons.

### 4.1 Collapse (scroll down)

Video `collapse.mp4` frames 6–46. The capsule top goes from 791.7 to 827.7 and
the text width from 69 to 51.

| t (ms) | top y | text w | text cy | side buttons |
|---|---|---|---|---|
| 0 | 791.7 | 69.0 | 816.0 | 100% |
| 30 | 795.0 | 67.3 | 818.5 | 85% |
| 47 | 798.3 | 65.7 | 821.2 | 48% |
| 63 | 802.7 | 63* | 824.7 | 18% |
| 80 | 806.7 | 61.7 | 827.5 | 0% |
| 113 | 813.7 | 58.3 | 833.2 | 0 |
| 146 | 819.0 | 55.7 | 837.2 | 0 |
| 181 | 822.3 | 54.0 | 839.8 | 0 |
| 215 | 824.7 | 52.7 | 841.8 | 0 |
| 263 | 826.7 | 52.0 | 843.3 | 0 |
| 330 | 827.7 | 51.0 | 843.8 | 0 (rest) |

\* The value is estimated because two labels overlapped in that frame.

- Fit (top y): **response 0.36 s, dampingFraction 0.91**. It is 99% settled at **0.31 s ≈ 19 frames at 60 fps**. Overshoot < 0.1%.
- The side buttons are fully transparent by about 80 ms (5 frames): an opacity ramp that also scales them to about 0.8 toward the capsule.
- The page menu and reload glyphs fade over the same 80 ms.
- Sheet: `anim-collapse-scroll-down.png`.

### 4.2 Expand (scroll up)

Frames 179–205.

| t (ms) | text w | text cy | tabs-button ink |
|---|---|---|---|
| 0 | 51.0 | 843.8 | 0 |
| 25 | 52.0 | 837.2 | 0 |
| 58 | 56.0 | 832.5 | 0 |
| 115 | 61.7 | 825.2 | 0 |
| 137 | 63.7 | 822.5 | 30% |
| 177 | 66.3 | 819.5 | 69% |
| 215 | 67.3 | 817.8 | 87% |
| 268 | 68.3 | 816.5 | 94% |
| 298 | 69.0 | 816.0 | 100% |

- Fit: **response 0.41 s, dampingFraction 0.87**. Settled at **0.31 s ≈ 18 frames**. Overshoot 0.4%.
- The side buttons fade in late, starting at about 130 ms (the second half).

### 4.3 Expand by tapping the pill

Frames 431–480. Sheet: `anim-expand-tap.png`.

| t (ms) | top y | text w | tabs ink | menu ink |
|---|---|---|---|---|
| 0 | 827.3 | 51.0 | 0 | 0 |
| 33 | 822.3 | 55.0 | 0 | 0 |
| 65 | 814.0 | 59.7 | 0 | 0 |
| 103 | 806.3 | 63.0 | 0 | 0 |
| 123 | 802.7 | 65.0 | 14% | 0 |
| 168 | 797.7 | 66.3 | 51% | 59% |
| 206 | 794.7 | 67.3 | 82% | 78% |
| 248 | 793.0 | 67.7 | 93% | 97% |
| 310 | 791.7 | 68.3 | 100% | 92% |
| 386 | 791.7 | 69.0 | 100% | 100% |

- Fit: **response 0.37 s, dampingFraction 0.90**. Settled at **0.31 s ≈ 18 frames**.
- Recommendation: use one spring, `.spring(response: 0.37, dampingFraction: 0.9)`, for collapse and expand. Drive the side-button opacity with a 0–80 ms linear ramp on collapse and a 120–300 ms ramp on expand.

## 5. Address editing

### 5.1 Layout

Images: `full-address-focus-keyboard.png`, `full-address-suggestions.png`, and
`full-address-edit-dark.png`.

| State | Field (capsule) | Close button | Notes |
|---|---|---|---|
| Software keyboard visible | **8, 517, 330 × 48** | **346, 517, 48 × 48** (`xmark` in a glass circle) | The keyboard (`inputView`) starts at y = 573, so the gap is **8 pt**. Side insets are 8 pt. |
| Hardware keyboard (no software keyboard) | 34, 792, 278 × 48 | 320, 792, 48 × 48 | Uses the same slots as the toolbar: the back button's slot merges into the field. |
| Text field | x = field.x + 12, width = field − 56. Left-aligned, 17 pt regular | | The **full URL** (`https://github.com/ghostty-org/ghostty`) is shown with all text **selected**: system selection highlight with a blue tint |
| Clear | `xmark.circle.fill`, 44 × 48 slot at the trailing edge of the field | | It is replaced by `mic` (Voice Search) when the field is empty |
| Keyboard | The Return key is the blue `→` "go" key | | |

### 5.2 Content shown while editing

- **Empty or initial (focused, nothing typed):** the start-page content (favorites and so on). A segmented control sits at the top: 16, 62, 370 × 44, with four segments. The first segment changes to `magnifyingglass` (search suggestions), followed by Bookmarks, Reading List, and History. A "Recent Searches / Clear All" list follows.
- **Typing:** the completion list `CompletionListTableView` has 16 pt side insets and rows 370 wide:
  - Top hit (switch to tab): 57 pt row with a 24 pt favicon at x 32 and a title in 17 pt semibold. The subtitle is 12–13 pt secondary, for example "en.wikipedia.org · Opened Tab".
  - Section headers are 15 pt semibold secondary gray: "Google Suggestions", "Bookmarks, History, and Tabs", "On This Page (39 matches)". Headers are 37–45 pt tall.
  - Suggestion rows are 52 pt tall, with `magnifyingglass` at x 34 and text at x 64. History rows use `clock` and are 57 pt tall. The find row uses `doc.text.magnifyingglass`.
- The background is the system grouped or plain background (light `#FFFFFF` for the list, `#F2F2F7` for the start page; dark `#000000`).

### 5.3 Focus transition (tap the URL)

Sheet: `anim-address-focus.png`. The tap is at t = 0.

| t (ms) | Event |
|---|---|
| 0–40 | The capsule begins to rise. The domain text crossfades to the full URL, which slides left to its alignment. The back and tabs circles begin to fade. |
| 30–130 | The page dims and blurs into the start/suggestions background with a crossfade. The bar rides up with the keyboard. |
| 130 | The keyboard top passes y ≈ 760. |
| 150–250 | The capsule morphs from 222 to 330 wide. The close (`xmark`) circle appears at the trailing edge, emerging from the tabs button's slot. |
| ~350 | Rest. The field top is at 517 and the keyboard top at 573. |

The overall curve follows the keyboard animation (UIKit keyboard spring, about
0.35 s, which is effectively `response 0.35, damping 1.0`). Total time is about
**21 frames at 60 fps**.

### 5.4 Go (Return)

Sheet: `anim-address-go.png`.

- At 0–200 ms the suggestions list crossfades out while the destination page, still loading, crossfades in.
- The field narrows back into the toolbar capsule and moves to y 792. The back and tabs circles fade back in.
- The capsule now shows `🔍 query` and `mic` (for a search) or the domain (for a URL).
- The whole sequence is about 0.30 s (≈ 18 frames).

## 6. Menus and previews

### 6.1 Page menu (tap ≡ in the capsule)

Images: `full-page-menu-light.png` (over red, which shows the tint) and
`full-page-menu-dark.png`.

| Property | Value |
|---|---|
| Container | One glass panel, **250 wide, x = 90–340** (left-aligned with the capsule's leading edge). It grows upward from the page-menu button: top ≈ 320, bottom ≈ 839. It is scrollable when the content is taller. |
| Corner radius | ≈ 32 pt (concentric with the capsule) |
| Rows | 42 pt for a single line, 62 pt for two lines. Icons are centered at x ≈ 130 (40 pt from the panel's left edge), 17–20 pt glyphs. Text starts at x ≈ 155 (65 pt inset), SF 17 regular, label color. Disclosure rows use `chevron.forward` at x 304. |
| Group separators | Hairlines from 117 to 330 (inset 27 pt), with 21 pt between groups |
| Item order (iOS 27) | Show Reader (when available, `doc.plaintext`) · Translate to English (`translate`, disabled or tertiary when not applicable) ‖ Share (`square.and.arrow.up`) · Add to Bookmarks (`bookmark`) · Add Bookmark to… (`book.badge.plus`) ‖ Find on Page (`doc.text.magnifyingglass`) · Page Zoom (`plus.magnifyingglass`) · Notify Me (`bell`) · Hide Distracting Items (`eye.slash`) ‖ Describe Extension (`plus.app`) ‖ Tab Actions › (`arrow.up.right.square`) · Privacy & Security › (`shield.lefthalf.filled`) · Request Desktop Website (`desktopcomputer`) · Hide Toolbar (`arrow.up.left.and.arrow.down.right`) · Website Settings… (`gear`) · Report Website Issue (`exclamationmark.bubble`) ‖ Customize Menu (`slider.horizontal.3`) |
| Material | Tinted glass. Over red, the fill is `#FF8189`, the same lightening as the bar. In dark mode the fill is about `#3A3A3C` at 85% with blur. |
| Toolbar while open | The back and tabs circles and the capsule contents dim to about 30%. The capsule itself is absorbed into the panel. |

**Open animation** (sheet `anim-page-menu-open.png`, the tap is at t = 0):

| t (ms) | State |
|---|---|
| 0–110 | The glass droplet detaches from the ≡ button. At 112 ms it is a 55 × 95 pt teardrop centered near (140, 700). |
| 133 | Blob about 95 × 175, with blurred content inside |
| 155–187 | Grows to about 130 × 250, then 160 × 330. Rows are visible but blurred and lensed at the edges. |
| 210 | About 175 × 380 |
| 262 | Nearly full size (250 × 510), corners still very round. The content is sharp. |
| 280–365 | Settles to the final frame with a slight stretch (about 1.5%) |
| ~400 | Rest |

Model this as a glass morph from the button. Animate the frame with
`spring(response 0.40, dampingFraction 0.78)`. Animate the content blur from
8 pt to 0 over the first 260 ms and the content opacity from 0 to 1 over
80–200 ms. Total time is about **24 frames**.

### 6.2 "···" / More

In this layout, the toolbar has **no** separate `···` button. The page menu
(≡) is the more menu. The tab overview has a separate `ellipsis` button at its
top-right (346, 66, 36 × 36; section 9.1). It opens a standard context menu with
tab-group and selection actions.

### 6.3 Link long-press preview

Images: `full-link-preview-light.png` and sheet `anim-link-preview.png`.

| Element | Frame |
|---|---|
| Lift highlight (0–100 ms) | A white rounded platter behind the link, scaled about 1.4×, with a soft shadow (iOS context-menu lift) |
| Preview card | **16, 78, 370 × ~534**, corner radius ≈ 30. The header is 44 pt: the domain (13 pt, secondary) on the left and "Hide preview" (13 pt, secondary) on the right. A hairline sits under the header. The page loads live, with the 2 pt blue progress bar under the header. |
| Action menu | **16, 637.7, 250 wide**, glass panel with rows of 42/62 pt: Open (`safari`) · Open in New Tab (`plus.square.on.square`) · Open in Tab Group › (`arrow.up.forward.app`) · Download Linked File (`arrow.down.circle`) · Add to Reading List (`eyeglasses`) · Copy Link (`doc.on.doc`) · Share… (`square.and.arrow.up`) |
| Backdrop | The page dims, with white going to `#CCCCCC` (about black at 20%) and a light blur |
| Timing | The lift appears at 0 ms. The preview grows from the link's location at about 245–330 ms and settles by about 420 ms with a slight overshoot. Use about `spring(0.42, 0.8)`. The menu morphs from the bottom-left at the same time. |

## 7. Status bar and top safe area

- The page **extends under the status bar**. The web view frame is 0,0 402 × 874. The safe-area top content inset is 62 pt (the start-page segmented control and page content begin at y = 62).
- The strip above the content is filled with the page's background color, **not** a Safari bar color. On `red.html`, rows 0–62 are exactly `#E01B24`, the same as the body (`full-status-bar-red-expanded.png`). Status-bar glyphs adapt to the luminance of the content: white on red or dark, black on white.
- **Scroll-edge effect:** when content scrolls under the status bar, Safari applies a **progressive blur plus a tint toward the page background**. The content is fully blurred from 0 to about 28 pt, transitions over 28 to about 50 pt, and is sharp below about 50 pt (`status-bar-scroll-edge-blur.png`, measured as the gradient energy per row). The same soft edge effect sits behind the bottom toolbar.
- There is no hairline or separator at the top.

## 8. Animation timing

At 60 fps, one frame is 16.7 ms. "Settle" means 99% of travel. Fits come from
tracked geometry. The simulator recorder dropped frames under load, so timings
for the tab and menu transitions are ±1–2 frames.

| Transition | Property tracked | response (s) | dampingFraction | Settle (ms) | Frames at 60 fps |
|---|---|---|---|---|---|
| Toolbar collapse (scroll down) | capsule top y | 0.36 | 0.91 | 308 | 19 |
| Toolbar collapse | URL text scale | 0.35 | 0.98 | 356 | 21 |
| Toolbar expand (scroll up) | URL text scale | 0.41 | 0.87 | 305 | 18 |
| Toolbar expand (tap pill) | capsule top y | 0.37 | 0.90 | 308 | 18 |
| Address focus (moves with the keyboard) | field y and width | ≈0.35 | 1.0 | ~350 | ~21 |
| Address Go back to the toolbar | field | ≈0.30 | ~1.0 | ~300 | ~18 |
| Tab overview open (page to card) | card width 402 → 177 | 0.22–0.30 | 1.0 | ~300 (grid blur clears by 380) | 14–18 (≈23 including fades) |
| Tab overview close (card to page) | card width 177 → 402 | 0.45 | 0.81 | 444 (y settles last) | 27 |
| Close tab in the overview | reflow of the remaining cards | ≈0.38 | ≈0.85 | ~380 | ~23 |
| New tab from the overview | scale from about 0.45 at the grid center | ≈0.40 | ≈0.9 | ~450 | ~27 |
| Page menu open (glass morph) | panel frame | ≈0.40 | ≈0.78 | ~400 | ~24 |
| Link preview | preview frame | ≈0.42 | ≈0.8 | ~420 | ~25 |
| Toolbar swipe (tab switch) | page offset (finger-driven, then spring) | ≈0.40 | ≈0.9 | ~300 after release | ~18 |

SwiftUI: `.spring(response: 0.37, dampingFraction: 0.9)` for the toolbar.
UIKit: `UISpringTimingParameters(dampingRatio: 0.9, response: 0.37)`.

## 9. Tab overview

Images: `full-tab-overview-light.png`, `full-tab-overview-dark.png`,
`tab-overview-cards-detail.png`, `tab-overview-top-controls.png`, and
`tab-overview-bottom-bar.png`.

### 9.1 Layout

```
 16                193 209               386
 ┌──────────────────┐ ┌──────────────────┐   ◀ card 177 × 249.3, r ≈ 18 (continuous)
 │ snapshot      (x)│ │               (x)│   close: 22 × 22 at (+151, +4)
 │                  │ │                  │
 └──────────────────┘ └──────────────────┘
   [fav] Title…            [🌐] Title          title row ≈ 23 pt, centered
   ↕ 16 gap (row pitch 288.3 = 249.3 + 23 + 16)
 ...
   (+)      ( Private | 6 Tabs )      (✓)      bottom bar, y 788–836
```

| Element | Value |
|---|---|
| Grid | 2 columns. Columns at x = **16** and **209**, so the side insets are 16 and the gutter is 16. |
| Card snapshot | **177 × 249.3** (aspect 0.71, close to the 402 : 566 visible page). Corner radius **≈ 18 pt** continuous (measured 16–18). Snapshot of the top of the page. No border. Soft shadow. |
| Title row | Below the card: favicon 16 pt (globe `globe` fallback) plus the title, SF 15–17 semibold, label color, one line with tail truncation, centered on the card. The title center is about 13 pt below the card. |
| Close | `xmark` in a 22 pt circle, fill `#EBEBEB` at 85% (light), at the card's top-right inset 4 pt (x+151, y+4). Hidden on the selected card. |
| Selected card | Same size. The current tab is scrolled into view. |
| Background | Blurred wallpaper gradient (warm beige/gray in light mode: `#ECDFD3` at the top to `#D2D3DB` at the bottom; dark is near-black with a tint) |
| Top controls | Glass circles **36 pt** (rendered at about 44 pt including the glass halo). Search (`magnifyingglass`) at 20, 66. Filter (`line.3.horizontal.decrease`) at 76, 66. More (`ellipsis`) at 346, 66. |
| Bottom bar | New tab `plus` glass circle **38, 788, 48 × 48**. Done is a **filled blue circle** 316, 788, 48 × 48 (`#0084F9`/`#0088FF`) with a white `checkmark`. The center holds a glass segmented capsule (`ScrollingCapsuleCollectionView` 38–364, segments "Private" at 130.8 w 55.7 and "6 Tabs" at 218.5 w 52.7). The selected segment is an inner glass pill. The text is SF 17 semibold; unselected text is secondary gray. |
| Tip | The first time it opens, a "Quickly Access All Tabs" tip popover appears at the top (dark screenshot) |

### 9.2 Open (tabs button): page shrinks into its card

Sheet: `anim-tab-overview-open.png`.

| t (ms) | Event |
|---|---|
| 0 | The full page begins to shrink toward its card slot (bottom-right here). Its corner radius goes from the screen radius (about 55) toward 18. The toolbar fades out. |
| 77 | Card about 259 pt wide (64% of the travel). The grid behind it is blurred and dimmed and scales up from about 1.06. |
| 145 | About 193 wide (93%). The grid is still blurred. The bottom bar (+, segment, ✓) fades in. |
| 187 | About 186 (96%). The grid blur is mostly clear. |
| 250–380 | Settle at 177. The grid is sharp. The titles and close buttons fade in last. |

### 9.3 Close (Done or tap a card): card grows into the page

Sheet: `anim-tab-overview-close.png`.

| t (ms) | Card width | Notes |
|---|---|---|
| 0 | 177 | The grid starts blurring and fading |
| 40 | 201 | |
| 75 | 251 | |
| 120 | 299 | |
| 162 | 347 | |
| 205 | 371 | The toolbar is fading in |
| 253 | 398 | It is about 20 pt low and still rising (y lags the scale) |
| 308–430 | 402 | y settles. The toolbar reaches full opacity. |

Fit: **response 0.45, dampingFraction 0.81** (slight overshoot of 1.3%).

### 9.4 Close a tab (× on a card)

Sheet: `anim-tab-close.png`.

- The counter updates immediately ("6 Tabs" → "5 Tabs").
- The closed card fades and shrinks (scale to about 0.9, opacity to 0) within about 100 ms.
- The following cards reflow to their new slots. A card moving from the left column of row N to the right column of row N−1 travels diagonally on a slight arc. All cards move at once, with no stagger.
- Spring of about 0.38 s, damping about 0.85. Done at about 380 ms.

### 9.5 New tab (+): start page

Sheet: `anim-new-tab.png`. Images: `full-start-page-light.png` and
`full-start-page-dark.png`.

- The new page appears at the center of the screen at about 45% scale, blurred, with a 40 pt corner radius. It grows to full screen over about 450 ms (88 ms at about 50%, 172 ms at about 85%). The overview blurs out behind it.
- The address field does not auto-focus. The toolbar shows the "Search or enter website" placeholder.

Start page layout:

| Element | Value |
|---|---|
| Background | `#F2F2F7` (light) / `#000000` (dark), or the custom wallpaper |
| Segmented control | 16, 62, 370 × 44. Glass capsule fill `#F6F6F9`. Selected segment pill `#E1E1E7` (light) / `#000` inner (dark). Four equal segments of 92–93 pt with icons `square.grid.3x3.fill`, `book`, `eyeglasses`, `clock`. |
| Onboarding card | 16, 126, 370 × 298.7, white `#FFF`, radius ≈ 26. The title "Start Page" is 17 semibold, centered. The close button is a `xmark.circle.fill` gray at 23 pt. The blue button is 330 × 34.3, `#0088FF`, a capsule with 17 semibold white text. |
| Section header | "Favorites", "Recently Viewed", "Privacy Report": SF 22 bold (about `title2`). Leading at x 16. Header height 34. |
| Favorites | 4 columns. Tiles are **72 × 72**, radius ≈ 16, fill `#CCCDD4` with a letter monogram in white 50 pt light, or the site icon. Pitch 99.3 (x = 16, 115.3, 214.7, 314). Labels are 12–13 pt, centered, 14.3 tall, at tile bottom + 8. |
| Spacing | Section gap about 30 pt. Cards 370 wide with 16 pt insets. |

### 9.6 Toolbar swipe: switch tabs

Sheet: `anim-toolbar-swipe-tab.png`.

- A horizontal pan on the address capsule moves the whole page with the finger, as a card with display-radius corners. The adjacent tab slides in from the side, scaled to about 0.93 and blurred, separated by a gap of about 12 pt.
- The capsule's label slides with its page, and the incoming page's label slides in.
- Swiping left past the last tab reveals a **new blank start page**: swiping past the end creates a new tab.
- On release, the page snaps with a spring of about 0.4 s, damping 0.9 (about 300 ms). The incoming page un-blurs and scales to 1.0 over the last 150 ms.

### 9.7 Edge-swipe back/forward and pull-to-refresh

- AXe's synthesized HID touches did **not** trigger Safari's `UIScreenEdgePanGestureRecognizer` (three attempts from x = 0–2). The edge-swipe was therefore **not captured**. Implement the standard iOS 26 behavior: the current page follows the finger with a left-edge shadow (black at about 20%, a 10 pt gradient). The previous page sits underneath with a parallax of −30% and is dimmed about 10%. Complete or cancel with a spring of about 0.35 s.
- Pull-to-refresh: not observed in the compact layout on iOS 27, where pages rubber-band at the top. Use the reload button.

## 10. Color tokens

| Token | Light | Dark |
|---|---|---|
| `toolbar.glass.fill` (over white or black) | `#FAFAFA`–`#FDFDFD` | `#1F1F1F`–`#232323` |
| `toolbar.glass.rim` | `#B0B0B0` (0.33 pt) plus `#D7D7D7` | `#5A5A5A` → `#3B3B3B` gradient |
| `toolbar.label` | `#000000` | `#FFFFFF` |
| `toolbar.glyph.disabled` | `#C5C5C7` | `#5B5B5D` |
| `progress` | `#0088FF` | `#0088FF` |
| `accent` / Done / primary button | `#0088FF` (`#0084F9` measured on glass) | `#0088FF` |
| `startPage.background` | `#F2F2F7` | `#000000` |
| `startPage.card` | `#FFFFFF` | `#1C1C1E` |
| `startPage.segment.fill` / `selected` | `#F6F6F9` / `#E1E1E7` | `#1C1C1E` / `#000000` |
| `favorite.tile` | `#CCCDD4` | `#3A3A3C` |
| `overview.background` | Blurred wallpaper, `#ECDFD3` → `#D2D3DB` | Blurred, near black |
| `overview.close.fill` | `#EBEBEB` at 85% | `#3A3A3C` at 85% |
| `menu.dim` (behind link preview) | Black at 20% | Black at 40% |
| `secondaryLabel` (headers, subtitles) | `#3C3C43` at 60% (≈ `#8A8A8E`) | `#EBEBF5` at 60% |

## 11. Implementation checklist for the streamed viewer

1. Show the remote frame full screen at 402 × 874. Report a 62 pt top safe area and **0** bottom inset to the page. The toolbar floats over the content.
2. Build three glass shapes (48 circle, 222 × 48 capsule, 48 circle) at y 792 with 34/8 spacing, in one glass container.
3. Label: host only, 17 pt Medium, centered. Use ≡ / ↻ (or ✕ while loading) inside the capsule, and draw a 2 pt `#0088FF` progress line along the bottom edge of the capsule.
4. Collapse on downward scroll (threshold about 15 pt) to a pill of text width + 38 × 32 at y 828. Expand on upward scroll, tap, or scroll-to-top. Use one spring (0.37 / 0.9).
5. Focus: move the field above the keyboard (8 pt gap, 8 pt insets, field 330 wide, close 48), show the full URL selected, and crossfade the page to suggestions.
6. Tab overview: 2 columns of 177 × 249.3 cards with 16 pt gaps and radius 18, plus a title row. Zoom open and close with springs of 0.25 / 1.0 and 0.45 / 0.81.
7. Page menu: a 250-wide glass panel growing from the ≡ button, with the listed items.

## Image index (`reference/safari/`)

| File | Shows |
|---|---|
| `toolbar-expanded-light.png` / `-dark.png` | Expanded toolbar over a plain background |
| `toolbar-capsule-zoom-3x.png` | Capsule at native 3× (rim and progress bar) |
| `toolbar-collapsed-light.png` / `-dark.png` | Mini pill |
| `toolbar-collapsed-over-content.png` | Pill over a busy page |
| `toolbar-glass-over-content-light.png` | Glass refraction over an image |
| `toolbar-glass-tinted-red.png` | Glass tint over a saturated page |
| `progress-bar-zoom.png` | Loading bar, magnified 2× |
| `full-page-wiki-light.png`, `full-page-wiki-dark-mode.png` | Whole screen with a real page |
| `full-status-bar-red-expanded.png` / `-collapsed.png` | Top safe-area fill |
| `status-bar-scroll-edge-blur.png` | Progressive blur under the status bar |
| `full-address-focus-keyboard.png`, `full-address-suggestions.png`, `full-address-edit-dark.png` | Editing |
| `full-tab-overview-light.png` / `-dark.png`, `tab-overview-cards-detail.png`, `tab-overview-top-controls.png`, `tab-overview-bottom-bar.png` | Overview |
| `full-start-page-light.png` / `-dark.png` | New tab |
| `full-page-menu-light.png` / `-dark.png` | Page menu |
| `full-link-preview-light.png` | Long-press preview |
| `anim-collapse-scroll-down.png`, `anim-expand-tap.png` | Toolbar collapse and expand frames |
| `anim-address-focus.png`, `anim-address-go.png` | Editing transitions |
| `anim-tab-overview-open.png`, `anim-tab-overview-close.png`, `anim-tab-close.png`, `anim-new-tab.png` | Overview transitions |
| `anim-toolbar-swipe-tab.png` | Tab swipe on the toolbar |
| `anim-page-menu-open.png`, `anim-link-preview.png` | Menu morphs |

Raw media (not in git): `~/nxios-ref/safari/` (screenshots) and
`~/nxios-ref/safari/vid/*.mp4` with frame folders and `ts.txt` timestamps.
