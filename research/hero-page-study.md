# Hero pages: hierarchy and interaction study

This note records a small, reproducible pass over six public landing pages. It is a design input for cmux surfaces, not a visual copy of any page.

## Method

`research/measure-sites.mjs` uses Playwright Chromium at 1440 × 900 CSS pixels, device scale factor 1. It waits for `domcontentloaded` plus 750 ms, aborts image, media, and font requests, and reads the first visible heading, supporting paragraph, navigation, CTA, and motion styles with `getComputedStyle`. It also writes a lightweight Playwright trace for each run; traces and the generated JSON stay out of git. The run was captured on 2026-10-24 UTC.

The page's first visible text block is not always the page's primary hero paragraph. The selector deliberately chooses the first visible paragraph after the heading, so the coordinates show the page's actual sequencing rather than an assumed component boundary. Color contrast is calculated from the sampled heading/paragraph and body colors using WCAG relative luminance; `oklch()` colors are converted to sRGB in the measurement script.

## Measured first fold

| Page | H1 size / line / weight / tracking | H1 top / box | Supporting copy | Nav height | CTA transition | Visible animation | Heading / copy contrast |
| --- | --- | --- | --- | ---: | --- | --- | ---: |
| Vercel | 64 / 64 / 400 / −3.84 px | 328 / 444 × 128 | 24 / 32 / 450 | 64 px | 150 ms, cubic-bezier(0.4, 0, 0.2, 1) | none in first 500 visible nodes | 17.18 / 8.10 |
| Linear | 64 / 64 / 510 / −1.408 px | 272 / 1282 × 128 | 15 / 24 / 400 | 73 px | 100 ms, cubic-bezier(0.25, 0.46, 0.45, 0.94) | none in first 500 visible nodes | 18.73 / 6.13 |
| Raycast | 64 / 70.4 / 600 / 0 | 371 / 540 × 141 | 18 / normal / 400 | — | 200 ms, ease-in-out | 1 s, ease, plus 3 s linear rotation | 20.04 / 20.04 |
| Stripe | 48 / 55.2 / 300 / −0.96 px | 229 / 908 × 276 | 32 / 35.2 / 300 | 76 px | 0 ms on selected CTA | scroll-linked; 240 ms cubic-bezier(0.45, 0.05, 0.55, 0.95) details | 8.80 / 4.42 |
| Supabase | 46 / 46 / 500 / 0 | 225 / 536 × 92 | 14 / 20 / 450 | 65 px | 200 ms, cubic-bezier(0.22, 1, 0.36, 1) | 300 ms fade; 35 s linear marquee | 20.30 / 5.42 |
| Resend | 96 / 96 / 400 / −0.96 px | 314 / 521 × 204 | 18 / 27 / 400 | 58 px | 200 ms, cubic-bezier(0.4, 0, 0.2, 1) | 1 s, ease-in-out; 30 s linear border rotation | 18.43 / 8.37 |

The common shell is striking: all six use a 16 px root size; navigation is 58–76 px tall; CTAs are 12–14 px; and the title sits between 225 and 371 px from the top. Contrast is generous for the title, while supporting copy ranges from 4.42:1 to 20.04:1. The generic feeling comes from repeating this shell and asking a single static title to carry the hierarchy. Color and type change, but the interaction contract is mostly “hover a link, then scroll.”

## Where the candy is

The memorable moments are short, staged, and tied to a visible state change:

1. **A clear first beat.** The title enters once (about 1 s on pages that expose an entrance animation), then settles. The page does not keep moving the primary message.
2. **A second beat with a job.** A marquee, scroll-linked detail, or preview gives the eye a reason to continue. It is spatially anchored to the copy rather than added as a decorative background.
3. **Small feedback with a different tempo.** Link and button transitions are 100–300 ms. They are quick enough to feel attached to input and long enough to be seen at 60 Hz.
4. **Strong negative space.** The hero title begins 225–371 px down, but the copy and demo are not centered into one undifferentiated block. The eye gets a title, a pause, and an interaction target.

## cmux prototype decisions

`prototypes/hero-gallery/index.html` turns these observations into three cmux-oriented variants behind a local gallery switch:

- **Focus** starts with a command target and a pane preview. Hovering the preview tracks a pointer-relative highlight; clicking the target opens a staged command surface.
- **Cloud** uses a three-step “route → warm → ready” rail. Selecting a step changes the preview and keeps the selected state in the same anchored panel.
- **Agent** uses a queue timeline. A single play action advances through three work states and stops; triggering it again clears any pending timers before restarting.

The gallery uses one motion vocabulary: `peek-open` (180 ms), `anchor-settle` (240 ms), and `stage-step` (340 ms). Every animation is transform/opacity-only, has a bounded end, and is disabled by `prefers-reduced-motion`. No new surface is wired into the app; the gallery is an off-by-default R&D prototype.

The target for a cmux hero is therefore a sequence rather than a decoration: title (one beat), anchored preview (one beat), then a user-triggered state change (one beat). The sequence should still read as a useful static layout with motion disabled.

## Prototype receipts

The local gallery was served from this checkout and exercised with the same Playwright Chromium harness at 1440 × 900. The run switched all three tabs, completed the Agent sequence in 1,200 ms, opened the command surface, selected a destination, and recorded a 1.27 MB trace plus a 173 KB WebM. There were no page errors. A reduced-motion run completed the same state sequence in 14 ms with computed transition and animation durations at 0.000001 s. The screenshot, trace, video, and extracted frame were kept in `/tmp` for visual inspection and are intentionally not committed.

## Re-run

From this checkout, install the research-only Playwright dependency and run:

```sh
npm install --prefix research --no-fund --no-audit
npx --prefix research playwright install chromium
node research/measure-sites.mjs
```

The script intentionally records URLs and computed values only. Do not commit screenshots or videos of third-party pages.
