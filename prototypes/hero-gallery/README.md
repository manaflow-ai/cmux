# cmux surface gallery

This is an off-by-default R&D prototype for reviewing hero hierarchy and interaction candy. It is a static page with three cmux-oriented variants:

- **Focus** anchors a command target to a pane preview and tracks the pointer with a bounded highlight.
- **Cloud** makes route, warm, and ready states visible in one rail.
- **Agent** exposes a three-step handoff sequence with a bounded play action.

Every variant uses the same motion vocabulary: `peek-open` (180 ms), `anchor-settle` (240 ms), and `stage-step` (340 ms). Sequences clear their timers when complete, on cancellation, or before unload. `prefers-reduced-motion` skips the staged movement while preserving the state changes.

Serve the repository root and open `/prototypes/hero-gallery/`:

```sh
python3 -m http.server 4173
```

The page has no external requests and no app wiring. It is intentionally a reviewable gallery rather than a shipping surface.
