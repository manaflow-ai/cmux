/// <reference types="bun" />
import { chromium } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
await gotoBenchPage(page, served);
await page.waitForFunction(() => "__debug" in window);
await page.evaluate(`window.__debug.seedRows(${Number(process.argv[2] ?? 3000)})`);
await page.locator(".acpmux-scroll").hover();
console.log(
  JSON.stringify(
    await page.evaluate(async () => {
      const sc = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const d = (window as any).__debug;
      await d.startFling(3, { wait: true, nominal_ms: 1000 / 120 });
      let added = 0,
        elems = 0,
        frames = 0,
        lastTop = sc.scrollTop,
        deltas: number[] = [],
        mounted: number[] = [];
      const mo = new MutationObserver((ms) => {
        for (const m of ms)
          for (const n of m.addedNodes)
            if (n instanceof HTMLElement && n.matches("[data-row-id]")) {
              added++;
              elems += 1 + n.querySelectorAll("*").length;
            }
      });
      mo.observe(sc, { childList: true, subtree: true });
      let run = true;
      const tick = () => {
        if (!run) return;
        frames++;
        deltas.push(Math.abs(sc.scrollTop - lastTop));
        lastTop = sc.scrollTop;
        mounted.push(sc.querySelectorAll("[data-row-id]").length);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      await d.startFling(3, { wait: true, nominal_ms: 1000 / 120 });
      run = false;
      mo.disconnect();
      deltas.sort((a, b) => a - b);
      mounted.sort((a, b) => a - b);
      return {
        frames,
        addedRows: added,
        rowsPerFrame: added / frames,
        elemsPerRow: elems / added,
        delta_p50: deltas[deltas.length >> 1],
        mounted_p50: mounted[mounted.length >> 1],
        scrollH: sc.scrollHeight,
        viewH: sc.clientHeight,
        rowsTotal: sc.scrollHeight / 3000,
      };
    }),
  ),
);
await browser.close();
await served.close();
process.exit(0);
