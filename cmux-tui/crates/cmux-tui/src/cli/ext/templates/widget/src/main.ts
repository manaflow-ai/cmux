// A widget, built on cmux-extension-sdk (the copy in ./sdk is the one this cmux ships). Add it
// from Edit Widgets > Add Widget on the New Tab page or in the sidebar. Save this file while
// `cmux ext dev` runs: cmux redraws every placed copy.
import { BigNumber, bySize, Caption, Spacer, widget, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

const two = (n: number) => String(n).padStart(2, "0")
const time = (ms: number) => {
  const at = new Date(ms)
  return `${at.getHours()}:${two(at.getMinutes())}`
}
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

// The export cmux-app.json names for cmux.widget/1. cmux ticks ctx.now() on the minute while the
// widget is shown, so the views that read it redraw; nothing else runs.
export const renderWidget = widget((ctx) =>
  WidgetFrame(
    [
      WidgetTitle("Hello from {{TITLE}}", { symbol: "clock" }),
      Spacer(),
      BigNumber(() => time(ctx.now())),
      bySize(ctx, {
        small: () => Caption(() => DAYS[new Date(ctx.now()).getDay()] ?? ""),
        medium: () => Caption(() => `${DAYS[new Date(ctx.now()).getDay()] ?? ""}, ${ctx.place === "sidebar" ? "in the sidebar" : "on the New Tab page"}`),
      }),
    ],
    { place: ctx.place }
  )
)
