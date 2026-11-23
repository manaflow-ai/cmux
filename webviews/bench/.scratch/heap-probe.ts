// scratch: heap per hidden agent page (not committed)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "../browsers";
import { servePane } from "../composer-arms";
const argv = process.argv.slice(2);
const flag = (n: string) => {
  const i = argv.indexOf(n);
  return i >= 0 ? argv[i + 1] : undefined;
};
const K = Number(flag("--k") ?? 5);
const SESSIONS = Number(flag("--sessions") ?? 3000);
const ROWS = Number(flag("--rows") ?? 120);
const NOSEED = argv.includes("--no-seed");
const SNAP = flag("--snap");
const releases: (() => unknown)[] = [];
const port = await servePane(path.resolve(import.meta.dir, "../.."), { unminified: true }, releases);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "heap-probe-"));
const proc = Bun.spawn(
  [
    "/usr/bin/google-chrome",
    "--headless=new",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--window-size=1100,820",
    "--process-per-site",
    "--disable-features=IntensiveWakeUpThrottling",
    "about:blank",
  ],
  { stdout: "ignore", stderr: "pipe" },
);
const reader = proc.stderr.getReader();
let text = "";
let ws: string | undefined;
while (!ws) {
  const { value, done } = await reader.read();
  if (done) break;
  text += new TextDecoder().decode(value);
  ws = /DevTools listening on (ws:\/\/\S+)/.exec(text)?.[1];
}
void (async () => {
  while (!(await reader.read()).done);
})().catch(() => undefined);
const browser = await chromium.connectOverCDP(ws!, { noDefaults: true });
try {
  const bcdp = await browser.newBrowserCDPSession();
  const context = browser.contexts()[0]!;
  await context.addInitScript((s) => {
    (globalThis as any).cmuxAcpmuxMockListSize = s;
  }, SESSIONS);
  const url = `http://127.0.0.1:${port}/?mock`;
  const focused = context.pages()[0] ?? (await context.newPage());
  const seed = async (page: any) => {
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60000 });
    if (NOSEED) return;
    const r = await page.evaluate(
      ([t]: any) => (window as any).cmuxAcpmuxDebug.loadSeed(t, { light: true }),
      [Math.round(ROWS / 2)],
    );
    if (r.error) throw new Error(r.error);
  };
  await focused.goto(url);
  await seed(focused);
  const cdp = await context.newCDPSession(focused);
  await cdp.send("Performance.enable");
  const heap = async () => {
    await cdp.send("HeapProfiler.collectGarbage");
    await cdp.send("HeapProfiler.collectGarbage");
    const m = (await cdp.send("Performance.getMetrics")).metrics;
    return Math.round((m.find((x: any) => x.name === "JSHeapUsedSize")!.value / 1048576) * 10) / 10;
  };
  await focused.waitForTimeout(3000);
  const h1 = await heap();
  const pages: any[] = [];
  for (let i = 0; i < K; i++) {
    const [p] = await Promise.all([
      context.waitForEvent("page"),
      bcdp.send("Target.createTarget", { url: "about:blank" }),
    ]);
    await p.goto(url);
    await seed(p);
    await focused.bringToFront();
    pages.push(p);
  }
  await focused.waitForTimeout(5000);
  const hk = await heap();
  const vis = await (pages[0] ?? focused).evaluate(() => document.visibilityState);
  // DOM nodes per hidden page
  const dom = await (pages[0] ?? focused).evaluate(() => document.getElementsByTagName("*").length);
  const domF = await focused.evaluate(() => document.getElementsByTagName("*").length);
  console.log(
    `PROBE k=${K} sessions=${SESSIONS} seed=${!NOSEED} heap1=${h1} heapK=${hk} perPage=${((hk - h1) / K).toFixed(1)} hiddenVis=${vis} domHidden=${dom} domFocused=${domF}`,
  );
  if (SNAP) {
    const chunks: string[] = [];
    cdp.on("HeapProfiler.addHeapSnapshotChunk", (e: any) => chunks.push(e.chunk));
    await cdp.send("HeapProfiler.takeHeapSnapshot", { reportProgress: false });
    fs.writeFileSync(SNAP, chunks.join(""));
    console.log(`snap written ${SNAP}`);
  }
} finally {
  await browser.close().catch(() => undefined);
  proc.kill();
  await proc.exited;
  fs.rmSync(profile, { recursive: true, force: true });
  for (const r of releases) await r();
}
