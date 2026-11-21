// Stills of the live line's "Thinking" handing over to a tool call, frame by frame, for review (Leo,
// 2026-11-21: "the animation for the Thinking swapping to tool calls also probably needs to be
// smoothed out"). Run with CMUX_SWAP_STILLS=<dir> (and CMUX_SWAP_LOOKS=before,exit,cross,slide):
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
import { swapFrameGate, readSwapFrame, type SwapFrame } from "./support/thinkingToolSwap";

await requireBrowserLane("thinking-tool-swap-stills.test.ts", async () => {
  setDefaultTimeout(240_000);
  const OUT = process.env.CMUX_SWAP_STILLS;
  const LOOKS = (process.env.CMUX_SWAP_LOOKS ?? "").split(",").filter(Boolean);
  const PAGE = "/test/browser/send-stream-motion.html";
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
        await page.waitForFunction(() => "__sendStream" in window);
        await page.getByText("History answer 6.").waitFor();
        const run = page.evaluate(() =>
          (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream
            .run({ scenario: "arrive-tool" })
            .then(() => true),
        );
        await page.waitForFunction(() => (window as unknown as { __phase?: string }).__phase === "begin");
        // The composer's stand-in would cover the live line on this page: hide it for the stills.
        await page.addStyleTag({
          content:
            ".acpmux-dock { visibility: hidden !important; } .acpmux-scroll, .acpmux-scroll * { mask-image: none !important; -webkit-mask-image: none !important; }",
        });
        const frames: (SwapFrame & { png: Buffer })[] = [];
        const full: Buffer[] = [];
        // The frame drawn before the call starts, every frame to its end, and 48 frames (400 ms) on.
        let landed = -1;
        let clipTop: number | undefined;
        for (let frame = 0; frame < 400 && (landed < 0 || frame - landed <= 48); frame += 1) {
          if (frame > 0)
            await page.evaluate(() => (window as unknown as { __advance: () => Promise<void> }).__advance());
          const now = await page.evaluate(readSwapFrame);
          if (landed < 0 && now.phase === "land") landed = frame;
          clipTop ??= Math.max(0, now.clipTop);
          const clip = { x: 0, y: clipTop, width: 760, height: 190 };
          frames.push({ ...now, png: await page.screenshot({ clip }) });
          if (frame === 0 || frame === landed + 48) full.push(await page.screenshot());
        }
        await page.evaluate(() => (window as unknown as { __release: () => void }).__release());
        await run;
        expect(frames.length).toBeGreaterThan(0);
        const dir = path.join(OUT!, `${look || "shipped"}-${theme}`);
        mkdirSync(dir, { recursive: true });
        frames.forEach((frame, index) =>
          writeFileSync(path.join(dir, `${String(index).padStart(2, "0")}.png`), frame.png),
        );
        full.forEach((png, index) => writeFileSync(path.join(dir, `full-${index ? "end" : "start"}.png`), png));
        writeFileSync(
          path.join(dir, "frames.json"),
          JSON.stringify(
            frames.map(({ png: _png, ...frame }) => frame),
            null,
            1,
          ),
        );
      } finally {
        await browser.close();
      }
    });
});
