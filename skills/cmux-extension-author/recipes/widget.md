# Recipe: a widget

A small tile for the New Tab grid and the sidebar, added from Edit Widgets > Add Widget.
Interface: `cmux.widget/1`
([contract](../../../cmux-tui/crates/cmux-app-host/interfaces/cmux.widget/1.json)).

`cmux-app.json`:

```json cmux-app.json
{
  "manifestVersion": 2,
  "id": "local/recipe-widget",
  "name": "Clock",
  "version": "0.1.0",
  "description": "The time, as a widget.",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.widget/1": {
      "export": "renderWidget",
      "title": "Clock",
      "symbol": "clock",
      "options": {
        "sizes": ["small", "medium"],
        "defaultSize": "small",
        "refresh": { "everySeconds": 60 },
        "places": ["newtab", "sidebar"]
      }
    }
  },
  "files": ["dist/"]
}
```

`src/main.ts`:

```ts src/main.ts
import { BigNumber, Caption, Spacer, widget, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

const two = (n: number) => String(n).padStart(2, "0")

// ctx: { place, size, instance, settings, refresh, now() }. cmux ticks now() on the refresh
// interval while the tile shows; the views that read it redraw, nothing else runs.
export const renderWidget = widget((ctx) =>
  WidgetFrame(
    [
      WidgetTitle("Clock", { symbol: "clock" }),
      Spacer(),
      BigNumber(() => {
        const at = new Date(ctx.now())
        return `${at.getHours()}:${two(at.getMinutes())}`
      }),
      Caption(ctx.place === "sidebar" ? "In the sidebar" : "On the New Tab page"),
    ],
    { place: ctx.place }
  )
)
```

Rules: `refresh.everySeconds` is at least 60; read time from `ctx.now()`, never a timer;
`WidgetFrame`, `BigNumber` and `Caption` set the sizes, so give none of your own.

```sh
cmux ext dev --once --json
```

<!-- recipe-check: shows "Clock" -->
Exit 0, and `scene` has the title `Clock` (the check mounts it as a small New Tab tile).
