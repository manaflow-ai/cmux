# cmux iOS design-system candidates

Four complete candidate design systems for the iOS app redesign, each expressed as a static, compiled gallery behind the debug menu (Design Gallery). Nothing here touches live app UI; the galleries exist so a direction can be picked by looking at real rendered screens instead of mockups.

Every system renders the same six screens from the same fixture data (`GalleryFixtures`), so comparison is apples-to-apples:

1. **Hub** — the agent/workspace list, the app's home
2. **Session** — a streamed terminal view with status header and input affordance
3. **Chat** — an agent conversation with a tool-call card and an approval request
4. **Activity** — the notification/event feed
5. **Settings** — account, paired Mac, appearance, notifications
6. **Specimen** — the system's palette, type scale, and core components side by side

## Shared rules (bind all four systems)

- **Status taxonomy** is the app's core information and is fixed across systems: `needsYou > failed > running > done > idle`. Every system encodes state redundantly (color + symbol or word), never color alone.
- Tap targets ≥ 44×44 pt. Primary actions live in the bottom half of the screen (thumb reach). Destructive actions are never adjacent to primary ones.
- Both light and dark are first-class in every system; the gallery has a per-system light/dark toggle.
- Reduce Motion degrades every animation to a crossfade.
- Terminal content is user-scaled and exempt from Dynamic Type; all other text tracks it.

## The four candidates

| # | System | One-line identity | Density | Glass usage |
|---|--------|-------------------|---------|-------------|
| 01 | Phosphor | Terminal-native instrument, dark-first, the terminal is the hero | high | minimal: floating command bar only |
| 02 | Atelier | Warm humanist companion, calm paper + serif accents | low | soft: nav on scroll + composer pill |
| 03 | Meridian | Liquid-glass native, content edge-to-edge, chrome floats | medium | everywhere chrome exists |
| 04 | Signal | Swiss status board, data-ink, fixed color legend | highest | single pinned summary strip |

Per-system token specs live in `phosphor.md`, `atelier.md`, `meridian.md`, `signal.md`.

## Philosophy sources

- Norman, *Design of Everyday Things*: visibility of system status drives the Hub (01/04 especially); redundant signifiers for state; mapping — the same slot means the same thing on every screen (04's hard rule).
- Claude iOS: warmth and calm as an anxiety-reducer when supervising agents (02).
- ChatGPT iOS: monochrome chrome, content-first, minimal navigation (03).
- iOS 26 HIG Liquid Glass: chrome floats above content and morphs; content itself is never glass (03, enforced everywhere).
- Tufte: data-ink ratio; color only as signal (04).
