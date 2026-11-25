// Stills of the live line's "Thinking" handing over to a tool call, frame by frame, for review (Leo,
// 2026-11-21: "the animation for the Thinking swapping to tool calls also probably needs to be
// smoothed out"). Run with CMUX_SWAP_STILLS=<dir> (and CMUX_SWAP_LOOKS=roll,exit,quick,cross,slide; CMUX_SWAP_THEME=light):
// each look writes PNGs of the live line's corner, one per 120 Hz frame from the call's arrival on,
// plus frames.json with, per frame, the leaving words' box and ink, the arriving words' box, the
// live line's and the arriving row's boxes and ink. Skipped otherwise: it asserts nothing (the
// assertions are thinking-tool-swap-frames.test.ts's).
//
// The page (browser/send-stream-motion.harness.tsx, `arrive-tool`) draws only when this script
// advances it once the call starts: frame callbacks wait for `__advance`, and every Web and CSS
// Animation is held and moved on by one 120 Hz slot per frame (turn-end-stills.test.ts's gate).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { recordSwap, SWAP_PAGE, swapFrameGate } from "./support/thinkingToolSwap";

await requireBrowserLane("thinking-tool-swap-stills.test.ts", async () => {
  setDefaultTimeout(240_000);
  const OUT = process.env.CMUX_SWAP_STILLS;
  const LOOKS = (process.env.CMUX_SWAP_LOOKS ?? "").split(",").filter(Boolean);
  const PAGE = SWAP_PAGE;
  const skip = !OUT;
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  beforeAll(async () => {
    if (skip) return;
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-thinking-tool-swap"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  for (const look of LOOKS.length ? LOOKS : [""])
    test.skipIf(skip)(`stills of Thinking handing over to a call (${look || "shipped"})`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const browser = await chromium.launch({
        headless: true,
        ...(process.env.CMUX_BROWSER_EXECUTABLE && { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }),
      });
      try {
        const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
        await page.addInitScript(swapFrameGate);
        const theme = process.env.CMUX_SWAP_THEME ?? "dark";
        await page.emulateMedia({ colorScheme: theme === "light" ? "light" : "dark" });
        await page.goto(`http://127.0.0.1:${port}${PAGE}?clock=frames&rows=1${look ? `&liveSwap=${look}` : ""}`);
        const shots: Buffer[] = [];
        const full: Buffer[] = [];
        let clipTop: number | undefined;
        const { frames } = await recordSwap(page, async (now, index, landed) => {
          clipTop ??= Math.max(0, now.clipTop);
          shots.push(await page.screenshot({ clip: { x: 0, y: clipTop, width: 760, height: 190 } }));
          if (index === 0 || index === landed + 48) full.push(await page.screenshot());
        });
        expect(frames.length).toBeGreaterThan(0);
        const dir = path.join(OUT!, `${look || "shipped"}-${theme}`);
        mkdirSync(dir, { recursive: true });
        shots.forEach((png, index) => writeFileSync(path.join(dir, `${String(index).padStart(2, "0")}.png`), png));
        full.forEach((png, index) => writeFileSync(path.join(dir, `full-${index ? "end" : "start"}.png`), png));
        writeFileSync(path.join(dir, "frames.json"), JSON.stringify(frames, null, 1));
      } finally {
        await browser.close();
      }
    });
});
