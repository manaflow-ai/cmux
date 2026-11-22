// Scratch capture for PR evidence (not committed): the real pane against the mock daemon, a busy turn
// ticking in the background, the hat tucked, the reader scrolled up; records a video and every
// frame's rect of Jump to latest and the hat's pill.
import path from "node:path";
import fs from "node:fs";
import { chromium } from "playwright";
const webviews = path.resolve(import.meta.dir, "..");
const out = path.resolve(process.argv[2] ?? "clip-out");
fs.mkdirSync(out, { recursive: true });
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const { port } = vite.httpServer!.address() as { port: number };
const browser = await chromium.launch({ headless: true });
for (const scheme of ["dark", "light"] as const) {
  const context = await browser.newContext({
    viewport: { width: 900, height: 700 },
    colorScheme: scheme,
    recordVideo: { dir: path.join(out, scheme), size: { width: 900, height: 700 } },
  });
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 90_000 });
  await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300));
  await page.evaluate(async () => {
    const m = await import("/src/agent-session/acpmux/chatDisplay.ts");
    m.setChatDisplay({ "agentPane.display.trayTucked": true });
  });
  const tick = page.evaluate(() =>
    (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 12, tick_ms: 100, sidebar_ms: 250, background_commands: 2 }),
  );
  await page.waitForTimeout(1500);
  await page.evaluate(() => {
    const s = document.querySelector<HTMLElement>(".acpmux-scroll");
    if (s) s.scrollTop = Math.max(0, s.scrollHeight - s.clientHeight - 2400);
  });
  const frames = await page.evaluate(
    () =>
      new Promise<any[]>((resolve) => {
        const rows: any[] = [];
        const end = performance.now() + 7000;
        const read = () => {
          const r = (sel: string) => {
            const b = document.querySelector(sel)?.getBoundingClientRect();
            return b ? [Math.round(b.left * 10) / 10, Math.round(b.top * 10) / 10, Math.round(b.width * 10) / 10] : null;
          };
          rows.push({
            jump: r(".acpmux-jump-latest[data-shown]"),
            pill: r(".acpmux-tray-pull__hat"),
            card: r(".acpmux-composer-box"),
            count: document.querySelector<HTMLElement>(".acpmux-tray-pull__count")?.dataset.count ?? null,
          });
          if (performance.now() < end) requestAnimationFrame(read);
          else resolve(rows);
        };
        requestAnimationFrame(read);
      }),
  );
  await page.screenshot({ path: path.join(out, `still-${scheme}.png`) });
  await tick.catch(() => {});
  const spread = (key: string, i: number) => {
    const v = frames.map((f) => f[key]?.[i]).filter((x) => typeof x === "number");
    return v.length ? { frames: v.length, min: Math.min(...v), max: Math.max(...v) } : null;
  };
  const report = {
    scheme,
    frames: frames.length,
    counts: [...new Set(frames.map((f) => f.count))],
    jumpX: spread("jump", 0),
    jumpY: spread("jump", 1),
    pillX: spread("pill", 0),
    pillY: spread("pill", 1),
    cardY: spread("card", 1),
  };
  console.log(`JBHP-STILL ${JSON.stringify(report)}`);
  fs.writeFileSync(path.join(out, `frames-${scheme}.json`), JSON.stringify(frames));
  await context.close();
}
await browser.close();
await vite.close();
