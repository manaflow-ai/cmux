# Interaction lab prototypes

This gallery is a deliberately small surface for tuning cmux NEXT interaction candy before a
production surface commits to one motion. It lives at `webviews/src/motion/interactionLab.gallery.tsx`
and loads automatically through the gallery registry.

The five variants isolate a hierarchy transition (`parent-child-shared-element`), a compositor-first
FLIP list (`list-flip-stagger`), pointer capture with a bounded release spring (`gesture-spring`),
retargetable Web Animations API playback (`interruptible-waapi`), and the same state change under
`prefers-reduced-motion` or the host's `data-cmux-motion="off"` policy (`reduce-motion`). The list
fixture inserts two rows so the 55 ms stagger can be inspected without a large data set; removal
fades an exit row, then reads the new layout and animates surviving rows from their previous boxes.

Every variant owns its handles. `useCleanupRegistry` cancels animations, pending frames and pointer
springs on unmount. The hierarchy and interruptible variants keep their child panel mounted while a
close is in flight, so the exit remains visible to the compositor. Gesture follow-through ends at a
rest threshold or the 850 ms deadline and cancels on a new pointer intent or pointer cancellation.
The reduce/off branch applies the final state immediately and listens for live preference changes.
No loop is unbounded and no reduced path leaves a spatial animation running.

## Evidence from one Chromium harness

The local trace run used Chromium 151.0.7922.34, a 1000x800 viewport, headless SwiftShader, one
warm-up gallery load, and the same requestAnimationFrame sampler for every variant. Each action was
wrapped with CDP `Tracing.start`/`Tracing.end` (`devtools.timeline`, `blink.user_timing`, `toplevel`,
`cc`, and `viz`); raw JSON traces were written to `/tmp/interaction-lab-traces` on the R&D VM and
are intentionally not committed. Frame values below are interval samples from that run; the 16.7 ms
cadence is the renderer's 60 Hz baseline, so a value at 16.8 ms is not treated as a long frame.

| Variant | Samples | p50 (ms) | p95 (ms) | max (ms) | >20 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| parent-child-shared-element | 66 | 16.7 | 16.8 | 16.8 | 0 |
| list-flip-stagger | 67 | 16.7 | 16.8 | 16.8 | 0 |
| gesture-spring | 67 | 16.7 | 16.7 | 16.8 | 0 |
| interruptible-waapi | 66 | 16.7 | 16.8 | 16.8 | 0 |
| reduce-motion | 66 | 16.7 | 16.8 | 16.8 | 0 |

These numbers are a receipt for this harness and viewport, not a cross-machine performance claim.
The gallery matrix remains the source of comparable Chromium/WebKit runs when a prototype is tuned
again. Its existing play runner records long-animation-frame data where Chromium exposes it and
falls back to rAF intervals elsewhere.

## Design references

- Material motion principles: <https://m1.material.io/motion/material-motion.html>
- WCAG 2.3.3, Animation from Interactions: <https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html>
- Compositor-friendly CSS animation: <https://web.dev/articles/animations-guide>
- FLIP layout transitions: <https://aerotwist.com/blog/flip-your-animations/>
- Web Animations API cancellation and reversal: <https://developer.mozilla.org/en-US/docs/Web/API/Animation/cancel> and <https://developer.mozilla.org/en-US/docs/Web/API/Animation/reverse>
- Pointer capture: <https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events>
- RAIL frame and input targets: <https://web.dev/articles/rail>

## Fast checks

From `webviews/`:

```sh
bunx tsc --noEmit --pretty false -p tsconfig.json
bun scripts/check-fixed-waits.ts
bun node_modules/vite-plus/bin/vp build --config vite.config.gallery.ts
```

`bun run typecheck` is equivalent on the supported Node runtime; this VM's Node 18 cannot load
Vite+'s `node:util` `styleText` export, so the direct TypeScript check is used here.
