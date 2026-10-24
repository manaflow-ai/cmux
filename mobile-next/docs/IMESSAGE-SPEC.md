# iMessage (Messages, iOS 26.5) measured reference

Measured 2026-10-12 from the real `com.apple.MobileSMS` app in the iOS 26.5 simulator (23F77) on an iPhone 17 Pro (402 x 874 pt, 3x, 1206 x 2622 px). The capture host was `mini-cmux8s-mac-mini` running Xcode 26.6. The goal is to rebuild the conversation list and transcript in SwiftUI to pixel and animation parity.

- Media (mp4, stills, contact sheets, PNG sequences): `~/cnm-refs/imessage/` on the dev Mac. Layout is under [Files](#files).
- The capture project and analysis scripts are in `mobile-next/tools/imessage-capture/`. How to re-run is under [Reproducing](#reproducing).

How sure each value is:

- **[ax]** comes from the accessibility frame the app reports (exact layout point).
- **[px]** was measured from 3x pixels. Precision is ±0.33 pt, and colors are sampled medians.
- **[fit]** was numerically fitted from 60 fps frames. The rms error is given.
- **[obs]** is a qualitative observation from the frame sequences.

All coordinates are points with the origin at the top left of the screen. The status bar was overridden to 9:41 with full bars.

---

## 0. Capture constraints you need to know

1. **The simulator's Messages app uses a fake local store.** It has exactly two seeded chats: `+1 (888) 555-1212` (contact "John Appleseed", initials JA) and `+1 (555) 564-8583` (Kate Bell, KB). **The two chats loop back into each other.** A message sent in one appears as a received message in the other, which is how the gray incoming bubbles were captured with no account. The store is in memory, so terminating the app wipes every message.
2. **New recipients never resolve.** A To: field stuck on "No Name, Searching" keeps the send button disabled, so only these two conversations exist. The list is too short to scroll for real.
3. **Sent bubbles are green SMS bubbles.** The header still says "iMessage · Encrypted", but no supported way to get blue iMessage bubbles turned up. Blue (#0088FF) appears only on the send button, tapback badges, and the swipe "unread" action. **Blue bubble colors in this document are not measured.**
4. **The status is always "Delivered".** "Read", "Not Delivered", and the delivery progress bar never occurred.
5. Recordings come from `simctl io recordVideo`. They are variable frame rate, and frames arrive every 16.7 ms while something animates, so **all animation timing is at 60 Hz.** The device is a 120 Hz ProMotion iPhone, so curves are sampled at half that rate. Durations and fitted springs are still valid.
6. A finger-driven gesture (swipe, edge pan, drag) is synthesized by XCUITest at a fixed velocity. The release velocity matches the velocity in the test, so treat the finger-tracking portion of those tables as synthetic.

---

## 1. Conversation list

### 1.1 Layout (light, large-title state)

| Element | Value | How sure |
|---|---|---|
| Nav bar, large title | y 62 to 168 (106 pt tall) | [ax] |
| Large title "Messages" | x 16, frame y 119.7, h 40.7. **SF Pro Display 34 Bold** (largeTitle). #000000 light, #FFFFFF dark | [ax][px] |
| Nav bar, collapsed (inline) | y 62 to 116 (54 pt). Inline title is centered at y 73.7, h 20.7, **17 Semibold** | [ax] |
| Row height | **86.67 pt** (rows at y 168, 254.67, … in large-title state; 116, 202.7 in inline state) | [ax] |
| Avatar | **45 x 45** circle at x **26**, vertically centered in the row (row y + 20) | [px] |
| Avatar fill (initials avatar) | Vertical gradient. Light: top #A9C1E1 to bottom #7682BB (center #98ACD4). Dark: #534E63 to #32284A. Initials are white, about 21 pt semibold (rounded) | [px] |
| Name label | x **83**, row y + 12, h 20.3. **17 Semibold**, #000 / #FFF. Width 218.7 when the time is present | [ax][px] |
| Message preview | x 83, row y + 21.7, w 303, up to **2 lines** (frame h 43), **15 Regular**, light #8A8A8E, dark #8D8D93 | [ax][px] |
| Time / date label | Right-aligned so its right edge is at **x 365.7**. Baseline row y + 14 to 32 (h 18). **15 Regular**, light #8B8B8F, dark #8B8B91. Format: "11:36 AM" for today, "12/31/00" for older | [ax][px] |
| Disclosure chevron | `chevron.forward`, frame 10.3 x 14 at x 375.7, row y + 16. About 15 pt semibold glyph. Light #C6C6C8, dark #454548 | [ax][px] |
| Status icon slot | Two 18 x 20 images at x 353.7 and 371.7, row y + 34.3 (used for mute and focus icons; empty here) | [ax] |
| Separator | From x **83** to x **386** (16 pt trailing inset), at the bottom of the row, 1 px hairline. Light #E8E8E8, dark #2A2A2C | [ax][px] |
| Background | Light #FFFFFF, dark #000000 | [px] |
| Row highlight (pressed) | #E5E5EA full row (light) | [px] |

### 1.2 Bottom search bar (iOS 26 floating glass toolbar)

| Element | Value |
|---|---|
| Glass container | x 28 to 374, y 798 to 846 (346 x 48), capsule, sitting **28 pt above the bottom edge** of the screen. Light: white glass with a soft shadow. Dark: #191919 glass |
| Search field | x 33, y 803, 336 x 38 |
| Magnifying glass | x 46, y 812, 20.7 x 19.3 (17 pt medium symbol), #000 / #F3F3F3 |
| Placeholder "Search" | 17 Regular, light #737373, dark #A3A3A3, starting at x ≈ 70 |
| Mic (Dictate) | x 335.7, y 811, 17.3 x 22 |

The search bar has no compose button and no Edit/filter button in this build of the simulator.

### 1.3 Swipe actions

The swiped row becomes a **rounded card** (fill #E5E5EA light, full row height 86.67, radius ≈ 26 to 28). It slides with the finger. The actions are separate **50 x 50 circular glass buttons** with a white glyph, outside the card. **[px]**

| Direction | Buttons when fully revealed (from the screen edge) | Colors |
|---|---|---|
| Swipe left (trailing) | Trash at x 342 to 392 (**10 pt from the edge**), Mute (bell.slash) at x 282 to 332 (**10 pt gap**). The card's right edge stops at x 271.8 (10 pt gap) | trash **#FF383C**, mute **#6155F5** |
| Swipe right (leading) | Mark unread (message.badge) at x 10 to 60 | **#0088FF** |

The buttons grow out of the card edge. Their height (diameter) tracks the drag: 13, 22, 31, 39, 44, 46, 48, 49, 50, 50.3, 51.7 (slight overshoot), then 50. While the finger keeps pulling past the reveal width, the button **stretches horizontally into a capsule** (trash up to 88 pt wide, unread up to 113 pt wide). On release it contracts back to a 50 pt circle over about 400 ms:

| frame after release | 0 | 2 | 4 | 6 | 8 | 10 | 12 | 14 | 16 | 18 | 20 | 24 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| trash width (pt) | 85.7 | 78.0 | 72.0 | 66.7 | 62.7 | 59.3 | 57.0 | 55.3 | 54.0 | 52.7 | 52.0 | 50.7 |
| unread width (pt) | 110 | 97.7 | 86.3 | 76.3 | 69.7 | 64.7 | 60.7 | 57.7 | 55.7 | 54.0 | 52.7 | 51.3 |

Fit **[fit]**: the curve is overdamped (ζ ≥ 1.6 at the edge of the search grid), with response 0.22 to 0.24 s and rms 0.7 to 0.9 pt. In SwiftUI use `.spring(response: 0.45, dampingFraction: 1.0)` or the native `.swipeActions`. Closing a revealed row (tapping elsewhere) shrinks the circles back into the card while the card returns, with no overshoot.

### 1.4 Long-press context menu (row)

[obs] The row lifts into a **preview card** showing the live transcript at the top of the screen (y ≈ 62 to 455, rounded ≈ 34 pt). The backdrop dims, and a glass menu appears at bottom left: x 16, width 250, rows 42 pt tall. Items are Pin, Mark as Unread, Hide Alerts, and Delete (red #FF383C). Each row has an SF Symbol at x ≈ 45 and a 17 Regular label at x ≈ 60.

Backdrop dim **[fit]**: the luminance of a white area goes from 249.8 to 201.9 (an effective black overlay of about 19%) over 13 frames (217 ms). It fits `spring(response: 0.32, dampingFraction: 0.80)` with rms 0.2. Dismissing reverses it with `response 0.32, damping 0.88`. **Use the native `.contextMenu(menuItems:preview:)`.** It produces this exact chrome.

### 1.5 Large title collapse, pull-down, and search

The list holds only two rows, so a real collapse could not be scrolled. Pulling down rubber-bands the whole list with the large title attached. The title moves down with the finger and springs back on release (about 4 to 6 frames to settle visually). Pushing to a chat while the list was scrolled kept the inline title. These are standard UIKit navigation bar behaviors, so **use `NavigationStack` + `.navigationTitle("Messages")` + `.navigationBarTitleDisplayMode(.large)`** rather than reimplementing them. The values in 1.1 match the system defaults.

Tapping Search moves the glass search field up above the keyboard, so the bar stays a bottom capsule. The rest of the screen shows "No Results" (a magnifying glass symbol, then "No Results" 17 Semibold over "Check the spelling or try a new search." 15 Regular gray). An **X close button** (38 pt glass circle) sits to the right of the field at x 347, y 484. See `1-conversation-list/stills/s1-search-*.png`. In SwiftUI this is `.searchable` with the iOS 26 toolbar placement.

### 1.6 Pinned grid and unread dot: not captured

The "Pin" context-menu action was invoked, but the simulator store never applied it, so no pinned avatar grid appeared. "Mark as Unread" had the same problem. **The unread dot and back-button badge could not be measured** (see section 8).

---

## 2. Transcript

### 2.1 Navigation bar (iOS 26 style, no bar background)

| Element | Value | How sure |
|---|---|---|
| Bar region | y 62 to 157.3 | [ax] |
| Back button | **44 x 44 glass circle** at x 16, y 62, white glass (#FEFEFE light, #2E2E2E dark). Chevron glyph 11 x 19 pt at x 31, y 74.7 (≈ 19 pt medium `chevron.backward`), #191919 / #F5F5F5. **No text label**; the accessibility label is "Messages" | [ax][px] |
| Contact avatar | **60 x 60** circle centered horizontally (x 171, y 62), same gradient as the list avatar | [ax][px] |
| Name pill | **Glass capsule 187.3 x 32.3** at x 107.3, y 117 (overlapping the avatar's bottom by 5 pt). Text is **17 Semibold** followed by a small gray `chevron.forward` (≈ 10 pt). The pill width hugs the text plus ≈ 14 pt padding on each side | [ax][px] |
| Scroll-edge effect | Content scrolls under the bar. The top ≈ 100 pt get a soft progressive blur/fade to the background (bubbles near y < 165 appear washed out) | [px][obs] |

### 2.2 Header and separators

| Element | Value |
|---|---|
| Service header | "iMessage" over "🔒 Encrypted", centered, two lines of **11 pt** (13.15 pt line), #8A8A8E. Cell starts 13.4 pt below the bar (y 170.7 for an unscrolled chat, h 26.3) |
| Date/time separator | "**Today** 11:27 AM": "Today" in **11 Semibold**, the time in **11 Regular**, #8A8A8E, centered, line h 13.3. **15 pt** below the service header and **7 pt** above the first bubble |
| A new time separator appears | when there is a time gap (not reproduced; all messages were the same day) |

### 2.3 Bubbles

| Property | Value | How sure |
|---|---|---|
| Outer margin | Sent bubbles end at x **385.84** and received bubbles start at x **16.17**, so **16 pt** from each screen edge | [px] |
| Max bubble width | **≈ 280.7 pt** (text view 262.7 + 2 x 9). That is **69.8% of the screen width**. Use `min(text, 0.70 * width)` | [ax][px] |
| Font | **SF Pro Text 17 Regular**. 'O' cap height measured 12.3 pt. Line height is **20.0 pt** (bubble heights: 1 line 40.33, 2 lines 60.33, 5 lines 120.33, 8 lines 180.33) | [ax][px] |
| Padding | Single-line bubble 40.33 tall, so vertical padding is **≈ 10 pt** above and below the 20 pt line. Horizontal is **14 pt** from the bubble edge to the glyph ink (UITextView frame = bubble inset by 9 pt, plus 5 pt line-fragment padding). **The tail does not add width**: tailed and untailed bubbles from the same sender share the same edge | [ax][px] |
| SwiftUI equivalent | `Text(...).font(.system(size: 17)).lineSpacing(-0.3)` (or rely on the default 17 pt line height of 20.29), `.padding(.horizontal, 13).padding(.vertical, 10)` (Text adds about 1 pt of side bearing) | [est from px] |
| Corner radius | **20 pt circular**, measured on 1-line pills (h 40.33, effectively a capsule) and on 8-line bubbles. Profile points match a circle of r = 20 within 0.1 pt down to y = 20. Use `min(20, h/2)` | [px] |
| Same-sender spacing (one group) | **4 pt** between bubble bodies (no tail on all but the last bubble) | [ax][px] |
| Different-sender or new-group spacing | **10 pt** between the body bottom and the next body top (the 7.45 pt tail hangs into that gap) | [ax] |
| Group break | A new group (and a tail on the previous bubble) also starts when the time gap is ≥ a few minutes ("See you at 7" 11:28 then "dinner" 11:31 got a tail and the 10 pt gap) | [ax] |
| Jumbo emoji (emoji only, ≤ 3) | No bubble. Glyphs ≈ 48 pt (the 🍜🍜 cell is 114 x 82, two glyphs ≈ 37 pt wide each), right-aligned to x ≈ 386 | [ax][px] |
| "Delivered" label | **11 Semibold**, #8A8A8E. Right edge at **x 366** (20 pt from the screen edge). Top is **5.7 pt** below the body bottom of the last sent bubble, h 13.3. Only under the most recent sent message | [ax][px] |
| Tapback badge | A **≈ 31 to 34 pt** blue circle (light #3DA5FF-ish gradient, the "liked" reaction) with a white glyph and a **2 pt background-colored ring**. Two trailing "thought" dots (≈ 9 pt and 5 pt) point to the bubble. It sits on the **top-leading corner of sent bubbles** (center ≈ 4 pt left of and 12 pt above the bubble's top-left) and the **top-trailing corner of received bubbles**. The bubble's cell height grows to 43.4 to make room | [px] |

### 2.4 Colors

| Token | Light | Dark |
|---|---|---|
| Background | #FFFFFF | #000000 |
| Sent SMS bubble | **Vertical screen-space gradient**: #4BDE70 at y ≈ 200, #43D668 at y ≈ 435, #3CCF61 at y ≈ 600, **#35C85A at y ≈ 765** (iOS systemGreen #34C759 at the bottom). It is fixed to the screen, not the bubble: a bubble's color changes as it scrolls | #32D35A at the top, #33CC59 mid, **#34C859** at the bottom (almost flat) |
| Received bubble | **#E9E9EB** (flat) | **#262629** (flat) |
| Sent text | #FFFFFF | #FFFFFF |
| Received text | #000000 | #FFFFFF |
| Secondary text (Delivered, separators, header) | #8A8A8E | ≈ #8D8D93 |
| Send button | **#0088FF** | **#0091FF** |
| Swipe trash / mute / unread | #FF383C / #6155F5 / #0088FF | (not captured in dark) |
| Composer placeholder "iMessage" | #C5C5C7 | #5F5F62 |
| Composer mic | #B4B8BF | #636466 |
| Keyboard background / key | #E2E4E7 / #FFFFFF | #171717 / #3D3D3D |
| Band between composer and keyboard | #F7F7F7 | #000000 |

For blue iMessage bubbles (not measured), the iOS 26 accent #0088FF light / #0091FF dark is the natural base. Apply the same kind of screen-space gradient as green: lighter at the top, ending at the accent at the bottom.

### 2.5 Bubble tail: exact path

Measured on the light "Ha, not that link 😅" sent bubble and "Perfect, I'm in 👍" received bubble, then fitted by rasterizing the parametric path at 3x and minimizing XOR area against the traced coverage mask. The XOR is 8.7 pt² over the 40 x 36 pt corner window, about 0.12 pt average boundary error. `tools/imessage-capture/scripts/tail_fit.py` does the fit. **The received tail is the exact mirror** (fitted separately, the parameters agree within 0.5 pt).

Traced outline of the tail corner of a sent bubble. Body W x H = 174.67 x 40.17. Points are relative to the body's bottom-right corner (dx is leftward, dy is downward):

```
right edge straight to dy=-18.4 · (0.0,-17.9) (1.0,-13.3) (1.7,-12.0) (4.3,-7.7) (5.9,-3.4)
neck (10.2,-1.3) (10.56,+0.3) (10.2,+2.3) (9.2,+4.3) (8.3,+5.3)
tip (8.33,+6.67) · underside back: (10.1,+6.67) (14.0,+4.67) (18.8,+1.33) (20.75,+0.33) → joins the bottom edge at dx ≈ 22.4
```

The tail hangs **7.45 pt below** the body. The tip is **7.9 pt inside** the body's trailing edge. The body's bottom-trailing corner is pulled in to a "neck" 10.5 pt in from the edge, and the underside meets the bottom edge 22.4 pt in.

SwiftUI `Shape`. `rect` is the **body** rect (text plus padding); draw it with `.frame(height: h + 7.45)` or let the tail overflow:

```swift
struct BubbleShape: Shape {
    var hasTail: Bool
    var isFromMe: Bool   // false = mirrored (received, tail bottom-leading)

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(20, h / 2), k: CGFloat = 0.5523   // circular corner
        var p = Path()
        p.move(to: .init(x: r, y: 0))
        p.addLine(to: .init(x: w - r, y: 0))
        p.addCurve(to: .init(x: w, y: r), control1: .init(x: w - r + k*r, y: 0), control2: .init(x: w, y: r - k*r))
        if hasTail {
            p.addLine(to: .init(x: w, y: h - 18.44))
            p.addCurve(to: .init(x: w - 10.5, y: h - 1.0),            // shoulder -> neck
                       control1: .init(x: w, y: h - 9.82), control2: .init(x: w - 6.62, y: h - 5.0))
            p.addCurve(to: .init(x: w - 7.9, y: h + 7.45),            // neck -> tip
                       control1: .init(x: w - 10.5, y: h + 4.0), control2: .init(x: w - 8.02, y: h + 3.95))
            p.addCurve(to: .init(x: w - 22.38, y: h),                 // tip -> underside -> bottom edge
                       control1: .init(x: w - 10.9, y: h + 7.51), control2: .init(x: w - 20.38, y: h))
        } else {
            p.addLine(to: .init(x: w, y: h - r))
            p.addCurve(to: .init(x: w - r, y: h), control1: .init(x: w, y: h - r + k*r), control2: .init(x: w - r + k*r, y: h))
        }
        p.addLine(to: .init(x: r, y: h))
        p.addCurve(to: .init(x: 0, y: h - r), control1: .init(x: r - k*r, y: h), control2: .init(x: 0, y: h - r + k*r))
        p.addLine(to: .init(x: 0, y: r))
        p.addCurve(to: .init(x: r, y: 0), control1: .init(x: 0, y: r - k*r), control2: .init(x: r - k*r, y: 0))
        p.closeSubpath()
        return isFromMe ? p : p.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
    }
}
```

The same path as SVG for W = 174.67, H = 40.17 (sent):

```
M20,0 H154.67 C165.72,0 174.67,8.95 174.67,20 V21.73 C174.67,30.35 168.05,35.17 164.17,39.17
C164.17,44.17 166.65,44.12 166.77,47.62 C163.77,47.68 154.29,40.17 152.29,40.17 H20
C8.95,40.17 0,31.22 0,20.17 V20 C0,8.95 8.95,0 20,0 Z
```

### 2.6 Composer (message entry view)

**Keyboard hidden (resting):**

| Element | Value |
|---|---|
| Entry view | y 805 to 874 (69 pt incl. the home-indicator area). No bar background; content scrolls under it |
| "+" button | **40 x 40 glass circle** at x **28**, y 806. Plus glyph 15.3 x 15.3 (≈ 20 pt light weight `plus`), #000 / #F3F3F3 |
| Text field capsule | x **80** to 374 (294 wide), y 805.7, **h 40.33**, radius 20 (capsule), white glass with a soft shadow (light) or #191919 (dark). 12 pt gap from the + button and 28 pt from the screen edge (it lines up with the list's search capsule) |
| Text inset | Text starts at x 91 (11 pt inside the capsule). Placeholder "**iMessage**" is 17 Regular |
| Mic | `mic` 22 x 22 at x 342, y 815, gray |

**Keyboard shown:** the whole bar re-insets to **16 pt** margins.

| Element | Value |
|---|---|
| Entry view | y 482 to 539 (57 pt), with a keyboard top (including the predictive bar) at **y 539.67** |
| "+" button | x **16**, y 483 |
| Text field | text frame x 79 to 341.7, capsule x ≈ 68 to 386, y 482.7, h 40.33 |
| Send button | **38 x 28 capsule** (radius 14), **#0088FF** / **#0091FF**, white `arrow.up` glyph about 13.7 x 16 (≈ 15 pt bold). Frame x 341.7 to 379.7, y 489 to 517, so **6.3 pt** from the capsule's trailing edge, vertically centered. It replaces the mic as soon as the text is non-empty. During the tap it shows a translucent light-blue pressed state for about 8 frames before the bubble appears |
| Growth | The field grows **20 pt per line** (one line of 17 pt text) upward from a fixed bottom. 8 lines gave a field 180.33 tall (y 342.7 to 523). The send button stays bottom-aligned (y 489 to 517 is unchanged), and so does the + button (y 483). Growth is animated per line: the bar's top edge moves by 20 pt in about 6 to 8 frames each time (see `3-composer-send/contact-sheets/s3-multiline-grow.png`) |
| Transcript inset | The transcript scrolls so the last bubble stays 9 to 10 pt above the composer capsule as the composer and keyboard move |

---

## 3. Animations

Times are relative to the first frame of motion. "Frame" means a 60 Hz frame (16.67 ms). SwiftUI spring equivalents use `.spring(response:dampingFraction:)`.

### 3.1 Push: list to transcript (tap a row)

[obs] Frame 1 shows the row highlight (#E5E5EA, about 1 frame before the push starts). The transcript slides in from the right as a **card with rounded leading corners (≈ device corner radius) and a soft leading shadow**. Underneath, the list **parallaxes left by 30% of the card's travel** and **dims** (white goes to lum 230, about 9% black, by the time the card covers it). In the new nav bar, the avatar and name pill **fade in from a blur** over frames ≈ 9 to 17, while the back button fades in.

Card position (from the left edge of the first sent bubble; final x = 131.33, so card x = value − 131.33):

| frame | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 20 | 22 | 25 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bubble x0 | 343.3 | 343.3 | 299.3 | 262.7 | 232.7 | 209.3 | 190.7 | 176.0 | 165.3 | 156.7 | 150.0 | 145.3 | 142.0 | 139.3 | 136.7 | 133.3 | 132.7 | 131.3 |
| card x | 212 | 212 | 168 | 131.3 | 101.3 | 78 | 59.3 | 44.7 | 34 | 25.3 | 18.7 | 14 | 10.7 | 8 | 5.3 | 2 | 1.3 | 0 |

The frame-to-frame decay ratio is a constant ≈ 0.76, a near-exponential (critically damped) approach. **Fit [fit]:** starting from card x = 402 (fully offscreen), **`spring(response: 0.30, dampingFraction: 0.98)`**, starting ≈ 2.5 frames before frame 5, rms 0.64 pt. The visible duration is ≈ 330 ms to 99%, and fully settled is ≈ 420 ms. The dark-mode push is identical (`sequences/push-dark`).

### 3.2 Pop: back button

Card offset (0 = covering, 402 = gone). The first six values are measured directly. The rest come from the list's parallax (list x = −0.295 x (402 − card)), which held at a constant ratio of 0.295 in every measured frame.

| frame | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| card x | 0 | 60.7 | 120.7 | 174.7 | 221.3 | 260.7 | 293.5 | 319.6 | 340 | 355.6 | 368.1 | 377.3 | 384 | 389.5 | 394.2 | 396.2 | 398.6 | 401 |
| list x | −118.6 | −100.7 | −83 | −67 | −53.3 | −41.7 | −32 | −24.3 | −18.3 | −13.7 | −10 | −7.3 | −5.3 | −3.7 | −2.3 | −1.7 | −1 | −0.3 |

**Fit [fit]:** **`spring(response: 0.24, dampingFraction: 1.0)`** (fitted 1.08), rms 3.6 pt, about 300 ms total. The list's dim fades out (lum 230 back to 253) over the same frames.

### 3.3 Interactive edge-swipe back

- **Tracking:** the card follows the finger 1:1. The bubble x0 moved 113 pt for a 128 pt finger travel, because the pan begins after about 15 pt of slop. The list parallax follows at 0.295.
- **Cancel** (released at card x = 113, about 28% of the width, with almost no velocity): the card returns with **`spring(response: 0.33, dampingFraction: 0.80)`** (rms 1.0 pt). It slightly undershoots (−0.7 pt) and settles in **≈ 14 frames (230 ms)**:

| frame after release | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| card x | 113.3 | 110.7 | 99.3 | 84 | 68 | 52.7 | 39.3 | 28.7 | 20 | 13.3 | 8.7 | 5.3 | 2.7 | 1.3 | 0 | −0.7 |

- **Complete** (flick at 1500 pt/s): the card keeps the finger's speed, about 29 pt per frame (x 0, 17, 51, 83, 113, 141, 170, 199, 226, 253, then offscreen). The pop finishes from that velocity with the same critically damped spring as 3.2. **Use the native `NavigationStack`**: this is the stock iOS 26 interactive pop, including the full-screen (not edge-only) back swipe.

### 3.4 Keyboard rise (tap the composer)

Keyboard top edge (y, pt) per frame, from 874 to the final 539.67:

| frame | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 16 | 18 | 20 | 23 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| y | 862.7 | 830.0 | 791.7 | 745.0 | 685.7 | 665.7 | 633.3 | 610.7 | 592.7 | 578.7 | 571.0 | 562.3 | 556.0 | 551.7 | 548.3 | 544.0 | 541.7 | 540.7 | 539.7 |

**Fit [fit]:** **`spring(response: 0.26, dampingFraction: 1.0)`** (fitted 1.04), rms 3.3 pt (frames 4 and 5 show 60 Hz capture jitter). That is ≈ 230 ms to 95% and ≈ 380 ms to settle. The composer bar rides on the keyboard, and its side insets animate from 28 to 16 pt. The transcript bottom inset follows. In SwiftUI, rely on the system keyboard avoidance (`.safeAreaInset(edge: .bottom)` for the composer). It uses this curve automatically.

### 3.5 Send: bubble flies from the composer (frame by frame)

Sequence: `sequences/bubble-send-light/` (129 PNGs at 60 fps; frame 1 is 133 ms before the bubble appears). Contact sheets are in `3-composer-send/contact-sheets/`.

Phases [obs]:

1. **Frames 1 to 9 (tap):** the send button shows a light-blue pressed state. The field still shows the text.
2. **Frame 10 (+17 ms):** the field text is gone. A **green bubble the size and shape of the field capsule** appears exactly over the field (x ≈ 69 to 386, y 482.7 to 530 including the tail), with the text at the same position as in the field. It renders **behind the composer's glass**, so it looks about 60% green.
3. **Frames 10 to 18 (≈ 130 ms):** the bubble's **leading edge slides right** (accelerating) while the trailing edge stays pinned at x 386. Width goes 317, 318, 318, 287, 275, 251, 225, 197, 171. The text slides with it. From frame 16 it starts to rise out from behind the top of the composer.
4. **Frames 19 to 21:** the bubble emerges above the composer at **≈ 79% scale** (width 126 against a final 160), still pinned right.
5. **Frames 21 to 50 (≈ 480 ms):** it rises into its slot and scales to 100%, anchored bottom-trailing, with a small bounce. Older messages scroll up by the same amount (40.3 + 4 pt). "Delivered" moves from the previous bubble to the new one: it fades out under the old bubble and fades in under the new one.

Lowest green component bbox (pt). Frames 10 to 20 are partly occluded by the composer glass, so treat them as the visible part only:

| frame | t ms | x0 | y0 | x1 | y1 | w | h | note |
|---|---|---|---|---|---|---|---|---|
| 9 | 133 | – | – | – | – | – | – | button pressed, text still in field |
| 10 | 150 | 68.7 | 482.7 | 386.0 | 530.0 | 317.3 | 47.3 | bubble = field rect |
| 11 | 167 | 68.0 | 482.7 | 386.0 | 530.0 | 318.0 | 47.3 | |
| 12 | 183 | 68.0 | 482.7 | 386.0 | 529.3 | 318.0 | 46.7 | |
| 13 | 200 | 99.3 | 482.7 | 386.0 | 528.7 | 286.7 | 46.0 | leading edge starts moving |
| 14 | 217 | 111.3 | 482.7 | 386.0 | 528.0 | 274.7 | 45.3 | |
| 15 | 233 | 134.7 | 482.7 | 386.0 | 525.3 | 251.3 | 42.7 | |
| 16 | 250 | 160.7 | 479.3 | 386.0 | 523.3 | 225.3 | 44.0 | starts rising |
| 17 | 267 | 189.3 | 476.0 | 386.0 | 523.3 | 196.7 | 47.3 | |
| 18 | 283 | 215.3 | 471.3 | 386.0 | 523.3 | 170.7 | 52.0 | |
| 21 | 333 | 260.0 | 458.0 | 386.0 | 488.0 | 126.0 | 30.0 | fully above the composer, scale ≈ 0.79 |
| 22 | 350 | 263.3 | 453.3 | 386.0 | 487.3 | 122.7 | 34.0 | |
| 23 | 367 | 263.3 | 449.3 | 386.0 | 486.0 | 122.7 | 36.7 | |
| 24 | 383 | 262.0 | 445.3 | 386.0 | 482.0 | 124.0 | 36.7 | |
| 25 | 400 | 259.3 | 442.0 | 386.0 | 479.3 | 126.7 | 37.3 | |
| 26 | 417 | 256.0 | 438.7 | 386.0 | 476.7 | 130.0 | 38.0 | |
| 27 | 433 | 252.7 | 435.3 | 386.0 | 474.7 | 133.3 | 39.3 | |
| 28 | 450 | 249.3 | 433.3 | 386.0 | 473.3 | 136.7 | 40.0 | |
| 29 | 467 | 246.0 | 430.7 | 386.0 | 472.0 | 140.0 | 41.3 | |
| 30 | 483 | 243.3 | 429.3 | 386.0 | 471.3 | 142.7 | 42.0 | |
| 32 | 517 | 237.3 | 426.7 | 386.0 | 470.7 | 148.7 | 44.0 | |
| 34 | 550 | 233.3 | 425.3 | 386.0 | 470.0 | 152.7 | 44.7 | |
| 36 | 583 | 229.3 | 424.0 | 386.0 | 470.7 | 156.7 | 46.7 | |
| 38 | 617 | 228.0 | 424.0 | 386.0 | 470.7 | 158.0 | 46.7 | |
| 40 | 650 | 226.7 | 424.0 | 386.0 | 471.3 | 159.3 | 47.3 | |
| 44 | 717 | 225.3 | 424.7 | 386.0 | 472.0 | 160.7 | 47.3 | max (≈ 0.4% overshoot) |
| 50 | 817 | 226.0 | 425.3 | 386.0 | 472.7 | 160.0 | 47.3 | settled |

Fits for phase 5 **[fit]**:

- Width (scale 0.79 → 1.0): `spring(response: 0.66, dampingFraction: 0.69)`, rms 0.06, 2% overshoot, 50% at 167 ms.
- Vertical (bottom edge 488 → 472.7): `spring(response: 0.33, dampingFraction: 0.51)`, rms 0.05. It overshoots **17%** (about 2.7 pt above the slot), then settles at ≈ 400 ms.

The total time from tap to rest is **≈ 680 ms**.

Recommended SwiftUI recreation:

1. On send, insert the message in the model immediately. Render the new bubble's final layout, but present it through a `matchedGeometryEffect` (or a manual overlay) whose source is the composer field's frame, placed under the composer glass layer (z-order below the composer).
2. Animate the frame from the field rect to the bubble rect with `spring(response: 0.33, dampingFraction: 0.55)`, with the trailing edge pinned (use `.frame(alignment: .trailing)`).
3. Animate the content `scaleEffect(0.79 → 1, anchor: .bottomTrailing)` with `spring(response: 0.6, dampingFraction: 0.7)`, starting when the bubble clears the composer (about 170 ms in).
4. Scroll older content up with the same vertical spring.
5. Move "Delivered" with a 0.2 s crossfade.

The multi-line send (`sequences/bubble-send-multiline-light`) follows the same choreography. The 8-line bubble starts as the 180 pt-tall grown field.

### 3.6 Grouping and tails during consecutive sends

When a new sent message joins the group, the previous bubble **loses its tail** and the gap shrinks from 10 to 4 pt as the new bubble lands. "Delivered" jumps to the newest bubble. See `3-composer-send/contact-sheets/s3-send-3-4.png` and `s3-send-4-tail.png` ("Ok" followed by "Leaving now 🚗").

### 3.7 Timestamp reveal (drag left on the transcript)

[obs] **Only sent bubbles move**: they translate left together. Received bubbles, the date separators, and "**Delivered**" stay put. Per-message time labels ("11:31 AM", **11 Regular**, #8A8A8E) are revealed at the right edge, right-aligned at x ≈ 399 and vertically centered on each bubble. While the finger drags at 300 pt/s, the bubbles move about 2.5 pt per frame (≈ 0.5 x finger), and they **clamp at −58 pt** (x1 386 → 328).

Release (from the held position, x1 339.3, back to 386):

| frame | 0 | 2 | 4 | 6 | 8 | 10 | 12 | 14 | 16 | 18 | 20 | 24 | 28 | 32 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| x1 | 339.3 | 350.0 | 358.0 | 364.7 | 369.3 | 373.3 | 376.7 | 379.3 | 380.7 | 382.0 | 383.3 | 384.7 | 385.3 | 386.0 |

**Fit [fit]:** overdamped **`spring(response: 0.36, dampingFraction: 1.28)`**, rms 0.26 pt, ≈ 530 ms to rest. Recreate it with a `DragGesture` on the transcript: offset sent rows by `max(-58, translation.width * 0.5)` and spring back on end.

### 3.8 Tapback menu (long-press a bubble)

[obs] Order of events after recognition (≈ 0.5 s hold):

1. The pressed bubble lifts slightly.
2. The backdrop dims and blurs, and the rest of the transcript recedes.
3. A **glass reaction capsule** grows out of a small "thought bubble" next to the pressed bubble. It holds six 44 x 44 tapback images at y 284 (heart, thumbs up, thumbs down, HAHA, !!, ?) at x 26.3 + 49·i, then recent emoji (😂, ❤️) at x ≈ 329 and 378. The capsule scrolls horizontally past the screen edge. A separate **"add custom emoji" 44 pt circle** with two trailing dots sits below the capsule near the bubble.
4. A **glass action menu**, 250 wide with 42 pt rows (Copy, Translate, Select, More…), grows from the bubble's leading/bottom edge at x 16, top ≈ 30 pt below the bubble.

Backdrop **[fit]**: lum 245.6 → 198.5 (≈ 19% darkening) over 13 frames (217 ms), **`spring(response: 0.32, dampingFraction: 0.80)`**. Dismissal **`response 0.32, dampingFraction 0.88`**. The menu and capsule scale in from ≈ 0.2 to 1.0 together with the dim (see `4-tapback-context-menu/contact-sheets/s4-menu-open-*.png`). For received bubbles the menu sits on the left. For sent bubbles the capsule and menu are right-aligned.

Selecting a reaction (heart): the menu collapses back into the bubble. The chosen glyph shrinks into the **badge** on the bubble's top corner (blue circle with a pink heart for "You loved this"). The dim fades out. The badge pops in with a small overshoot. The whole sequence takes ≈ 1.0 s (see `s4-heart-select.png` and `s4-thumb-select.png`). Afterwards the list preview reads "You liked “See you at 7”".

### 3.9 Interactive keyboard dismissal (drag down on the transcript)

Keyboard dismiss mode is **interactive**. Once the finger crosses the keyboard's top edge, the keyboard and composer track the finger 1:1. The keyboard top moved 5 to 6.6 pt per frame at a 350 pt/s finger speed: 500.3, 505.3, 510, 515, 520, … 703.3. Releasing below the midpoint with downward velocity animates the rest of the way out with the keyboard spring (3.4, reversed). A partial drag that stops short springs back up. Use `.scrollDismissesKeyboard(.interactively)`.

### 3.10 Scrolling

- Fling and deceleration are standard `UIScrollView`. The transcript is bottom-anchored, starts at the bottom, and keeps the newest message visible while sending.
- A status-bar tap scrolls to the top with the standard UIKit scroll-to-top animation.
- Content scrolls under the transparent nav bar and the composer, with the iOS 26 scroll-edge blur/fade at both ends.

### 3.11 App launch

[obs] On a cold launch the app zooms from the icon. The list appears with its large title and rows already populated (no row-by-row animation). See `0-launch/contact-sheets/s0-launch.png`.

---

## 4. Recommended SwiftUI parameters (summary)

| Interaction | Recommendation |
|---|---|
| Push / pop / edge swipe | Native `NavigationStack`. Measured: push `spring(0.30, 0.98)`, pop `spring(0.24, 1.0)`, cancel `spring(0.33, 0.80)`, 30% parallax and ≈ 9% dim |
| Keyboard | System avoidance. Measured `spring(0.26, 1.0)`, top at y 539.67 with the predictive bar |
| Bubble send | Field rect → bubble rect `spring(0.33, 0.55)` with the trailing edge pinned, under the composer glass, then `scaleEffect` 0.79 → 1 at the bottom-trailing anchor with `spring(0.6, 0.7)`. About 680 ms in total |
| Timestamp reveal | Drag factor 0.5, clamp −58 pt, release `spring(0.36, 1.28)` (or `spring(0.4, 1.0)`) |
| Swipe actions | Native `.swipeActions` (iOS 26 renders 50 pt glass circles). Release `spring(0.45, 1.0)` |
| Context menu / tapback backdrop | Native `.contextMenu` for the list. For the tapback overlay, dim to 19% with `spring(0.32, 0.80)` in and `spring(0.32, 0.88)` out |
| Bubble metrics | 17 pt text, 20 pt line, 10 / 14 pt padding, radius 20, margins 16, max width 70%, spacing 4 (group) / 10 (break) |

---

## 5. Dark mode

Stills: `7-light-dark-stills/` (`s7-dark-list`, `s7-dark-transcript-a(-top)`, `s7-dark-transcript-b`, `s7-dark-composer-keyboard`, `s7-dark-tapback-menu`). Light equivalents use the same names with `light`. Geometry is identical to light. The colors are in 2.4. Notes:

- The nav back button and pill use dark glass (#2E2E2E). The avatar gradient is darker (#534E63 → #32284A).
- The sent gradient is nearly flat (#32D35A → #34C859).
- The search capsule and composer field are #191919. The keyboard is #171717 with #3D3D3D keys.

---

## 6. Accessibility identifiers (useful for a UI-test parity harness)

`ConversationList` (list collection view) · cells labelled "name, preview, time" · `TranscriptCollectionView` · `CKBalloonTextView` (bubble text) · `BackButton` · `ConversationTitle` · `MessageEntryView` · `messageBodyField` (placeholder "iMessage") · `sendButton` · tapback images `heart_108`, `thumbsup_073`, `thumbsdown_069`, `haha-ENG_114`, `exclamation_103`, `question_080` · `AdditionalDimmingOverlay` · `Sticker` (bubble containers while the menu is open).

---

## 7. Files

On the dev Mac, under `~/cnm-refs/imessage/`:

| Folder | Contents |
|---|---|
| `0-launch/` | `s0-launch.mp4`, still, contact sheet |
| `1-conversation-list/` | `s1-list.mp4` (pull-down, swipes, context menu, search), `s8-pin.mp4`, `s1b-unpin.mp4`, `s9-unread(-dark).mp4`, stills (`s1-swipe-left-actions`, `s1-swipe-right-actions`, `s1-row-context-menu`, `s1-search-*`), contact sheets per gesture |
| `2-push-pop/` | `s2-push-pop.mp4` and `s2-push-pop-dark.mp4` (push, partial edge swipe, full edge swipe, push, back button, push to the KB chat), contact sheets. The `s2-transcript-*.png` stills there were taken in **dark** mode (the dark run overwrote the light ones); the light transcript stills are in `7-light-dark-stills/` |
| `3-composer-send/` | `s3-composer.mp4` (keyboard rise, typing, send, multi-line, grouped sends, timestamp drag), `s3b-timestamp-hold.mp4`, stills (`s3-keyboard-up`, `s3-composer-typed`, `s3-composer-multiline`, `s3-grouped-tails`, `s3-timestamps-revealed-*`), contact sheets |
| `4-tapback-context-menu/` | `s4-tapback.mp4`, stills (`s4-tapback-menu-received/sent`, `s4-after-heart`, `s4-after-thumb`, `s4-context-menu-copy`), contact sheets |
| `5-keyboard-dismiss/`, `6-scroll/` | mp4, stills, contact sheets |
| `7-light-dark-stills/` | Light and dark stills of the list, transcripts, composer with keyboard, and tapback menu, plus `s7-light.mp4` / `s7-dark.mp4` |
| `sequences/` | Full 60 fps PNG sequences (1206 x 2622): `bubble-send-light` (129), `bubble-send-multiline-light` (133), `push-light` (84), `push-dark` (84), `pop-back-button-light` (70) |
| `analysis/` | `results.txt` (every per-frame track and fit), `segments.txt` (time window per transition), `marks.txt` (test step timestamps relative to each recording), `motion-segments.txt` (detected animation windows per video) |

Capture project and scripts (no media), in `mobile-next/tools/imessage-capture/`:

| Path | Purpose |
|---|---|
| `project.yml`, `Host/` | XcodeGen project: an empty host app plus the `IMsgUITests` UI-test bundle driving `XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")` |
| `UITests/Support.swift` | Helpers: send, go to the list, onboarding dismissal, `CNM-MARK` timestamps |
| `UITests/Seed.swift` | Seeds the loopback conversation (both sides) |
| `UITests/Scenarios.swift` | One test per recorded scenario (`testS0Launch` … `testS9Unread`) with stills and accessibility dumps |
| `UITests/Explore.swift` | Accessibility-tree dump and send probe used during discovery |
| `scripts/run_scenario.sh` | Records one scenario with `simctl io recordVideo` around `xcodebuild test-without-building` |
| `scripts/run_all.sh` | The full capture pass in the right order |
| `scripts/frame_times.py` | Finds animation windows in a variable-frame-rate recording |
| `scripts/extract_frames.sh`, `extract_all.sh`, `segments.txt`, `contact.py` | 60 fps PNG extraction and labelled contact sheets |
| `scripts/track2.py` | Connected-component tracker (green / blue / dark / color predicates) with spring and bezier fitting |
| `scripts/fit_series.py` | Spring fit for a hand-assembled series with unknown start time |
| `scripts/edge_scan.py`, `lum.py` | Keyboard edge tracking and backdrop-dim luminance |
| `scripts/sample_colors.py` | Colors and glyph ink boxes |
| `scripts/outline.py`, `tail_fit.py`, `bubbles.py` | Sub-pixel bubble outline tracing and the tail-path fit |
| `scripts/analyze_all.sh` | Regenerates `analysis/results.txt` |
| `scripts/track.py` | First-pass single-color tracker (superseded by `track2.py`) |

## 8. Not captured, and why

| Item | Reason |
|---|---|
| Blue iMessage bubbles | The simulator store sends everything as green SMS. No supported switch was found, and the bubbles were not faked |
| "Read", "Not Delivered", sending progress | The fake store always reports "Delivered" |
| Live arrival animation of an incoming message | `simctl` cannot inject messages. The loopback delivers into the *other* chat, which cannot be on screen at the same time. Incoming bubbles were measured only as static layout |
| Unread dot (list) and unread count badge (back button) | "Mark as Unread" never changed state in the fake store |
| Pinned conversations grid | "Pin" never applied in the fake store |
| Real large-title collapse while scrolling | Only two conversations exist (new recipients never resolve), so the list never scrolls. Pull-down rubber banding was recorded. Use the native navigation bar |
| Link previews | The URL message from the loopback chat never rendered |
| Group chats, typing indicator, photos, audio, stickers | Need real accounts or other recipients |
| 120 Hz timing | Simulator recording is 60 Hz |
| Swipe-action colors in dark mode | The swipe gestures were recorded only in light mode |

## Reproducing

On a Mac with Xcode 26.6 and the iOS 26.5 runtime (`brew install xcodegen ffmpeg`, plus Python 3 with `pillow numpy`):

```bash
cd ~/cnm/imessage                      # ROOT; scripts read $CNM_ROOT
U=$(xcrun simctl create cnm-imsg-1 com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5)
echo "$U" > udid; xcrun simctl boot "$U"; xcrun simctl bootstatus "$U" -b
cp -R <repo>/mobile-next/tools/imessage-capture proj && (cd proj && xcodegen generate)
(cd proj && xcodebuild -project IMsgCapture.xcodeproj -scheme IMsgUITests -destination id=$U -derivedDataPath ../dd build-for-testing)
proj/scripts/run_all.sh                # ~25 min (each long-press waits ~60 s for XCTest idle)
PY=venv/bin/python proj/scripts/extract_all.sh && proj/scripts/analyze_all.sh
xcrun simctl delete "$U"
```

The time windows in `segments.txt` belong to the 2026-10-12 recordings. After a re-run, find the new windows with `frame_times.py` and `analysis/marks.txt`.
