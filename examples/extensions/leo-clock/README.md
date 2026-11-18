# Leo clock: a big animated clock on every New Tab

`local/leo-clock`, from the Leo collection. A New Tab page with an analog face whose hands sweep,
a flip clock whose digits slide, or a ring per city showing how far through its day it is; and a
world clock section for the sidebar. JS ticks once a second; cmux's renderer runs every motion in
between (`.animation`, `.transition`, `.loop`, `.trim`, `.glow`, `.gradient`), so it costs nothing.

```sh
cmux ext dev examples/extensions/leo-clock
cmux settings set tabs.newTabApp local/leo-clock
```

Settings > Apps > Leo clock: `variant` (analog, flip, ring), time zones, 12-hour clock, your name.
Edit `src/main.ts` (colors are in `INK`); `src/time.ts` is the wall-time math.
