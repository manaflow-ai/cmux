/// <reference types="bun" />
import { chromium } from "./browsers";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html", { dev: false });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(300)`);
  const out = await page.evaluate(async () => {
    const root = document.getElementById("root")!;
    root.style.width = "900px";
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    for (let f = 0; f < 10; f += 1) await new Promise(requestAnimationFrame);
    scroller.scrollTop = scroller.scrollHeight;
    for (let f = 0; f < 30; f += 1) await new Promise(requestAnimationFrame);
    const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")];
    const view = scroller.getBoundingClientRect();
    const near = rows.filter((r) => {
      const b = r.getBoundingClientRect();
      return b.bottom > view.top - view.height && b.top < view.bottom + view.height;
    });
    const elements = document.querySelectorAll("#root *").length;
    const offscreen = rows.filter((r) => r.classList.contains("acpmux-row--offscreen")).length;
    const skipped = rows.filter(
      (r) => !r.checkVisibility({ contentVisibilityAuto: true } as CheckVisibilityOptions),
    ).length;
    const spans = rows.map((r) => {
      const b = r.getBoundingClientRect();
      return Math.round(((b.top - view.top) / view.height) * 10) / 10;
    });
    console.log(JSON.stringify({ offscreen, skipped, first: spans[0], last: spans.at(-1), viewH: view.height }));
    const rowElements = rows.reduce((n, r) => n + r.querySelectorAll("*").length, 0);
    // Pure forced layout at a new width, no observers (they run in the rendering step).
    const times: number[] = [];
    const widths = [760, 700];
    for (let i = 0; i < 10; i += 1) {
      await new Promise(requestAnimationFrame);
      const t = performance.now();
      root.style.width = `${widths[i % 2]}px`;
      void root.offsetHeight;
      times.push(performance.now() - t);
      await new Promise((d) => setTimeout(d, 300));
    }
    // Same, with rows away from the view skipped by content-visibility (their size held).
    const far = rows.filter((r) => !near.includes(r));
    for (const r of far) {
      r.style.contentVisibility = "hidden";
      r.style.containIntrinsicSize = `auto ${r.offsetHeight}px`;
    }
    await new Promise(requestAnimationFrame);
    const cv: number[] = [];
    for (let i = 0; i < 10; i += 1) {
      await new Promise(requestAnimationFrame);
      const t = performance.now();
      root.style.width = `${widths[i % 2]}px`;
      void root.offsetHeight;
      cv.push(performance.now() - t);
      await new Promise((d) => setTimeout(d, 300));
    }
    const med = (a: number[]) => [...a].sort((x, y) => x - y)[a.length >> 1]!.toFixed(2);
    return {
      offscreen,
      skipped,
      spanFrom: spans[0],
      spanTo: spans.at(-1),
      viewH: view.height,
      rows: rows.length,
      near: near.length,
      elements,
      rowElements,
      forcedLayout: med(times),
      forcedLayoutFarHidden: med(cv),
    };
  });
  console.log(JSON.stringify(out));
} finally {
  await browser.close();
  await served.close();
}
