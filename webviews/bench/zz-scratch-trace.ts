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
  const run = (widths: number[]) =>
    page.evaluate(async (widths) => {
      const root = document.getElementById("root")!;
      for (let i = 0; i < 20; i += 1) {
        await new Promise(requestAnimationFrame);
        performance.mark("step");
        root.style.width = `${widths[i % widths.length]}px`;
        await new Promise((d) => setTimeout(d, 700));
      }
    }, widths);
  await run([760, 700]);
  console.log(
    "images",
    JSON.stringify(
      await page.evaluate(() => {
        const out: Record<string, number> = {};
        for (const el of document.querySelectorAll<HTMLElement>("#root *")) {
          const cs = getComputedStyle(el);
          for (const p of [
            "backgroundImage",
            "maskImage",
            "webkitMaskImage",
            "listStyleImage",
            "borderImageSource",
          ] as const) {
            const v = (cs as any)[p];
            if (v && v !== "none") {
              const k = `${p} ${el.closest(".acpmux-row") ? "row" : "chrome"} ${String(v).slice(0, 50)}`;
              out[k] = (out[k] ?? 0) + 1;
            }
          }
          if (el.tagName === "IMG" || el.tagName === "svg" || el.tagName === "CANVAS") {
            const k = el.tagName + (el.closest(".acpmux-row") ? " row" : " chrome");
            out[k] = (out[k] ?? 0) + 1;
          }
        }
        return out;
      }),
    ),
  );
  if (process.argv[3] === "cv") {
    const n = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      let n = 0;
      for (const r of document.querySelectorAll<HTMLElement>(".acpmux-row")) {
        const b = r.getBoundingClientRect();
        if (b.bottom > view.top - view.height || b.top < view.bottom + view.height) {
        }
        if (b.bottom < view.top - view.height || b.top > view.bottom + view.height) {
          r.style.contentVisibility = "auto";
          r.style.containIntrinsicSize = `auto ${b.height}px`;
          n += 1;
        }
      }
      return n;
    });
    console.log("cv rows", n);
    await run([760, 700]);
  }
  for (const widths of [[760, 700], [700]]) {
    await browser.startTracing(page, {
      categories: ["devtools.timeline", "disabled-by-default-devtools.timeline", "blink.user_timing", "v8.execute"],
    });
    await run(widths);
    const trace = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: any[] };
    const main = trace.traceEvents.find((e) => e.name === "thread_name" && e.args?.name === "CrRendererMain");
    const ev = trace.traceEvents.filter((e) => e.tid === main.tid && e.pid === main.pid);
    ev.sort((x, y) => x.ts - y.ts || (y.dur ?? 0) - (x.dur ?? 0));
    const tasks = ev.filter((e) => e.ph === "X" && e.name === "RunTask" && e.dur);
    const byKind = new Map<string, number>();
    const selfIn = new Map<string, number>();
    let j = 0;
    for (const t of tasks) {
      const end = t.ts + t.dur;
      const inner = [];
      while (j < ev.length && ev[j].ts < t.ts) j += 1;
      for (let k = j; k < ev.length && ev[k].ts < end; k += 1) if (ev[k].ph === "X" && ev[k] !== t) inner.push(ev[k]);
      const first = inner.find((e) =>
        [
          "TimerFire",
          "FunctionCall",
          "FireAnimationFrame",
          "BeginMainThreadFrame",
          "EventDispatch",
          "RunMicrotasks",
          "MajorGC",
          "MinorGC",
          "ParseHTML",
          "UpdateLayoutTree",
          "Layout",
          "Paint",
        ].includes(e.name),
      );
      const fn = first?.args?.data?.functionName || first?.args?.data?.url?.slice(-30) || "";
      const kind = first
        ? `${first.name}${fn ? ` ${fn}:${first.args?.data?.lineNumber ?? ""}` : ""}`
        : `(none:${inner[0]?.name ?? "-"})`;
      byKind.set(kind, (byKind.get(kind) ?? 0) + t.dur / 1000);
      // Leaf-ish attribution: per-name self time inside this task.
      const stack: any[] = [];
      for (const e of inner) {
        while (stack.length && stack.at(-1).end <= e.ts) stack.pop();
        if (stack.length) stack.at(-1).child += e.dur ?? 0;
        const rec = { name: e.name, end: e.ts + (e.dur ?? 0), dur: e.dur ?? 0, child: 0 };
        stack.push(rec);
        (e as any).__rec = rec;
      }
      for (const e of inner) {
        const r = (e as any).__rec;
        selfIn.set(r.name, (selfIn.get(r.name) ?? 0) + (r.dur - r.child) / 1000);
      }
    }
    console.log(`widths=${widths} per step, tasks by kind:`);
    for (const [n, ms] of [...byKind.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12))
      console.log(`  ${(ms / 20).toFixed(2)} ms  ${n}`);
    console.log(`  self time by event:`);
    for (const [n, ms] of [...selfIn.entries()].sort((a, b) => b[1] - a[1]).slice(0, 18))
      console.log(`  ${(ms / 20).toFixed(2)} ms  ${n}`);
  }
} finally {
  await browser.close();
  await served.close();
}
