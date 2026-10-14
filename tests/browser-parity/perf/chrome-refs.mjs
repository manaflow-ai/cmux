// The Chrome reference for bench.mjs, timed in this process on headless
// Google Chrome with a throwaway profile:
//   pw-ai  Playwright's `_snapshotForAI()`, its AI snapshot (full, then
//          incremental after the change).
// Recorded reference B AX columns in perf/results came from an offline renderer
// that is no longer in this repository; report.mjs shows them when present.
import { loadPlaywright } from "../lib/dev-driver.mjs";

const DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const VIEWPORT = { width: 1280, height: 800 };

export async function createChromeReferences({ runs, mutate }) {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const timed = async (fn) => {
    const t = Date.now();
    const v = await fn();
    return [v, Date.now() - t];
  };
  return {
    async page(p) {
      const context = await browser.newContext({ viewport: VIEWPORT, userAgent: DESKTOP_UA });
      const page = await context.newPage();
      page.on("dialog", (d) => d.dismiss().catch(() => {}));
      const pw = { name: p.name, runs: [] };
      try {
        await page.goto(p.url, { waitUntil: "load", timeout: 90_000 }).catch((e) => {
          if (!/timeout/i.test(e.message)) throw e;
        });
        await page.waitForTimeout(p.settle);
        for (let i = 0; i < runs; i++) {
          const [snap, ms] = await timed(() => page._snapshotForAI({ track: "perf" }));
          pw.runs.push({ snapMs: ms, treeChars: snap.full.length });
          if (i === 0) pw.tree = snap.full;
        }
        await page.evaluate(mutate);
        {
          const [snap, ms] = await timed(() => page._snapshotForAI({ track: "perf" }));
          pw.diff = { snapMs: ms, diffChars: (snap.incremental || "").length, printed: String(snap.incremental || "").slice(0, 4000) };
        }
        const refs = [...pw.tree.matchAll(/\[ref=(\w+)\]/g)].map((m) => m[1]).filter((r) => !r.startsWith("f"));
        pw.refCount = refs.length;
        const last = refs.pop();
        if (last) {
          const [, ms] = await timed(() => page.locator(`aria-ref=${last}`).textContent({ timeout: 10_000 }).catch(() => null));
          pw.locatorMs = ms;
        }
      } catch (e) {
        pw.error = pw.error || String(e.message || e);
      } finally {
        await context.close().catch(() => {});
      }
      return { name: p.name, tools: { "pw-ai": pw } };
    },
    async overhead() {
      return null;
    },
    async leak() {
      return null;
    },
    close: () => browser.close(),
  };
}
