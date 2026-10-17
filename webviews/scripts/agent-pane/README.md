# Agent pane visual matrix

`visual-matrix.mjs` is a Playwright behavior proof against the in-page mock daemon. It runs the real agent pane and records the visual states needed for review: streaming, queue/steer, pull request chip, permission cards, image replies, wallpaper, light/dark themes, and narrow/normal/wide widths.

```sh
heavy --mem 4G bun scripts/agent-pane/visual-matrix.mjs --out ../artifacts/agent-pane-visual
```

The output contains one fast-clock WebM per case, sampled PNG frames, `metrics.json` with a CLS-style score plus per-frame maximum jumps, `contact-sheet.png`, and `verdict.md`. Use `--cases` to run one or more named cases. The runner disables Vite file watching because it is a bounded capture job intended to run concurrently on Linux workers.
