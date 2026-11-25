/// <reference types="bun" />
import { chromium } from "./browsers";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html", { dev: false });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(${process.argv[2] ?? 300})`);
  await page.evaluate(async () => {
    const root = document.getElementById("root")!;
    root.style.width = "900px";
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    for (let f = 0; f < 10; f += 1) await new Promise(requestAnimationFrame);
    scroller.scrollTop = scroller.scrollHeight;
    for (let f = 0; f < 30; f += 1) await new Promise(requestAnimationFrame);
  });
  const run = (widths: number[]) => page.evaluate(async (widths) => {
    const root = document.getElementById("root")!;
    for (let i = 0; i < 20; i += 1) {
      await new Promise(requestAnimationFrame);
      performance.mark("step");
      root.style.width = `${widths[i % widths.length]}px`;
      await new Promise((d) => setTimeout(d, 700));
    }
  }, widths);
  await run([760, 700]);
  if (process.argv[3] === "cv") {
    const n = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      let n = 0;
      for (const r of document.querySelectorAll<HTMLElement>(".acpmux-row")) {
        const b = r.getBoundingClientRect();
        if (b.bottom > view.top - view.height || b.top < view.bottom + view.height) {}
        if (b.bottom < view.top - view.height || b.top > view.bottom + view.height) {
          r.style.contentVisibility = "auto"; r.style.containIntrinsicSize = `auto ${b.height}px`; n += 1;
        }
      }
      return n;
    });
    console.log("cv rows", n);
    await run([760, 700]);
  }
  for (const widths of [[760, 700], [700]]) {
    await browser.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-devtools.timeline", "blink.user_timing", "v8.execute"] });
    await run(widths);
    const trace = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: any[] };
    const main = trace.traceEvents.find((e) => e.name === "thread_name" && e.args?.name === "CrRendererMain");
    const ev = trace.traceEvents.filter((e) => e.tid === main.tid && e.pid === main.pid);
    const sum = new Map<string, number>();
    const count = new Map<string, number>();
    for (const e of ev) if (e.ph === "X" && e.dur) { sum.set(e.name, (sum.get(e.name) ?? 0) + e.dur / 1000); count.set(e.name, (count.get(e.name) ?? 0) + 1); }
    const names = ["RunTask", "ThreadControllerImpl::RunTask", "FunctionCall", "TimerFire", "FireAnimationFrame", "UpdateLayoutTree", "Layout", "PrePaint", "Paint", "Layerize", "UpdateLayer", "ParseHTML", "ScheduleStyleRecalculation", "HitTest", "MajorGC", "MinorGC", "V8.GC_MC_BACKGROUND_MARKING", "v8.run", "EventDispatch", "BeginMainThreadFrame", "Commit", "ResizeObserver::BroadcastObservations", "LocalFrameView::NotifyResizeObservers", "IntersectionObserverController::computeIntersections", "ComputeIntersections", "UpdateLayerTree"];
    console.log(`widths=${widths} per step:`);
    for (const [n, ms] of [...sum.entries()].sort((a, b) => b[1] - a[1]).slice(0, 30)) console.log(`  ${(ms / 20).toFixed(2)} ms  x${((count.get(n) ?? 0) / 20).toFixed(1)}  ${n}`);
    void names;
  }
} finally { await browser.close(); await served.close(); }
