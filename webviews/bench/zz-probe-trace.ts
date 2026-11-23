// scratch (not committed): a Chrome trace of 120 keys typed into the idle pane; top events by thread
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
const releases: (() => unknown)[] = [];
const port = await servePane(process.cwd(), {}, releases);
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
await page.goto(`http://127.0.0.1:${port}/?mock`);
await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60000 });
await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(60, { light: true }));
const prompt = page
  .locator(".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']")
  .first();
await prompt.click();
await page.waitForTimeout(1500);
await browser.startTracing(page, {
  categories: [
    "devtools.timeline",
    "disabled-by-default-devtools.timeline",
    "blink",
    "cc",
    "viz",
    "gpu",
    "disabled-by-default-devtools.timeline.frame",
  ],
});
const KEYS = 120;
for (let i = 0; i < KEYS; i++) {
  await page.keyboard.press("abcdefghijklmnopqrstuvwxyz"[i % 26]!);
  await page.waitForTimeout(20);
}
await page.waitForTimeout(300);
const buf = await browser.stopTracing();
const trace = JSON.parse(buf.toString());
const events = (trace.traceEvents ?? trace) as any[];
const threads = new Map<string, string>();
for (const e of events) if (e.ph === "M" && e.name === "thread_name") threads.set(`${e.pid}:${e.tid}`, e.args.name);
const sum = new Map<string, { ms: number; n: number; max: number }>();
for (const e of events) {
  if (e.ph !== "X" || !e.dur) continue;
  const t = threads.get(`${e.pid}:${e.tid}`) ?? "?";
  const key = `${t} | ${e.name}`;
  const s = sum.get(key) ?? { ms: 0, n: 0, max: 0 };
  s.ms += e.dur / 1000;
  s.n++;
  s.max = Math.max(s.max, e.dur / 1000);
  sum.set(key, s);
}
const rows = [...sum.entries()].sort((a, b) => b[1].ms - a[1].ms).slice(0, 45);
for (const [k, s] of rows)
  console.log(
    `${(s.ms / KEYS).toFixed(2).padStart(7)} ms/key  n=${String(s.n).padStart(5)}  max=${s.max.toFixed(1).padStart(6)}  ${k}`,
  );
require("fs").writeFileSync("/tmp/ct-probe/trace-L0.json", buf);
await browser.close();
for (const r of releases) await r();
process.exit(0);
