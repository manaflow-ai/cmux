// scratch (not committed): rAF interval floor, blank page vs the idle chat pane, same headless Chrome
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
const releases: (() => unknown)[] = [];
const port = await servePane(process.cwd(), {}, releases);
const browser = await chromium.launch({ headless: true });
const q = (xs: number[], p: number) => [...xs].sort((a, b) => a - b)[Math.round((xs.length - 1) * p)];
async function frames(page: any, label: string) {
  const xs: number[] = await page.evaluate(
    () =>
      new Promise<number[]>((resolve) => {
        const out: number[] = [];
        let last: number | undefined;
        const tick = (t: number) => {
          if (last !== undefined) out.push(t - last);
          last = t;
          if (out.length < 300) requestAnimationFrame(tick);
          else resolve(out);
        };
        requestAnimationFrame(tick);
      }),
  );
  console.log(
    label,
    "frames",
    xs.length,
    "p50",
    q(xs, 0.5).toFixed(1),
    "p95",
    q(xs, 0.95).toFixed(1),
    "over16",
    xs.filter((x) => x > 16.9).length,
  );
}
const blank = await browser.newPage({ viewport: { width: 1100, height: 820 } });
await blank.setContent("<html><body>blank</body></html>");
await frames(blank, "blank");
const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
await page.goto(`http://127.0.0.1:${port}/?mock`);
await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60000 });
await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(60, { light: true }));
await page.waitForTimeout(3000);
await frames(page, "pane-idle");
const anims = await page.evaluate(() =>
  document
    .getAnimations()
    .map(
      (a: any) =>
        `${a.constructor.name}:${a.animationName ?? a.transitionProperty ?? ""}:${(a.effect?.target as Element)?.className?.toString().slice(0, 60)}`,
    ),
);
console.log("running animations", anims.length, anims.slice(0, 20));
await browser.close();
for (const r of releases) await r();
process.exit(0);
