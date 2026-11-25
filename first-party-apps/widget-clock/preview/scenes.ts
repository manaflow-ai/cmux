// Draws the packed widget in the fake host at a fixed instant and returns the scene ops it sends,
// for the tests and the preview fixtures the gallery renders (preview/build.ts).
// The instant: Monday, November 16, 2026, 9:41:12 AM in Los Angeles. Run with TZ=America/Los_Angeles.
import { FakeHost, type Op } from "cmux-extension-sdk/testing"

export const AT = Date.UTC(2026, 10, 16, 17, 41, 12)

export interface Render {
  size: "small" | "medium" | "large"
  settings?: Record<string, unknown>
  /** "widget" (default): the widget host's mount, whose context has now(); "section": a host without it. */
  surface?: "widget" | "section"
  /** The person's IANA zone in the widget context (default Los Angeles, the fixtures' zone). */
  timeZone?: string
  /** The instant to draw (default AT, 9:41 AM). */
  at?: number
}

export async function renderScene(source: string, render: Render): Promise<{ ops: Op[]; host: FakeHost }> {
  const host = new FakeHost("", { app: { id: "cmux/clock", version: "1.0.0", locale: "en-US" }, apiVersion: "1.0.0", settings: {} })
  // Pin the clock before the app's script runs, so nothing reads the real time.
  host.eval(`Date.now = () => ${render.at ?? AT}`)
  host.eval(source)
  const widget = (render.surface ?? "widget") === "widget"
  host.mount("w", "renderClock", {
    surface: render.surface ?? "widget",
    size: render.size,
    place: "newtab",
    instance: `preview-${render.size}`,
    settings: render.settings ?? {},
    ...(widget ? { locale: "en-US", timeZone: render.timeZone ?? "America/Los_Angeles" } : {})
  })
  await host.settle()
  return { ops: host.batches("w").flat(), host }
}
