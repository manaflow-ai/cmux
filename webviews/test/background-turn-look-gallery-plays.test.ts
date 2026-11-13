// Every gallery variant whose play hovers or opens a background turn's line plays clean in both
// background-turn-look arms (backgroundTurnLook.experiment.ts). The inline arm (default) draws no
// such line, so a play that waits on it threw and the frame never showed the state (Codex review of
// cmux#40973, F2); the line arm still draws and plays it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-turn-look-gallery-plays.test.ts", async () => {
  setDefaultTimeout(240_000);
  const CASES: { entry: string; variant: string }[] = [
    { entry: "agent-pane.background-reactions", variant: "weighed-hover" },
    { entry: "agent-pane.lone-system-rows", variant: "background-update-hover" },
    { entry: "agent-pane.lone-system-rows", variant: "background-tasks-run-hover" },
    { entry: "agent-pane.transcript-system-rows", variant: "scheduled-check-hover" },
    { entry: "agent-pane.background-runs", variant: "open" },
    { entry: "agent-pane.transcript", variant: "background-turns" },
    { entry: "agent-pane.transcript", variant: "background-turns-nothing-to-open" },
  ];
  const ARMS = ["inline", "line"];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("background turn look gallery plays", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const entry of new Set(CASES.map((one) => one.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: CASES.find((one) => one.entry === entry)!.variant },
      });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const { entry, variant } of CASES)
    for (const arm of ARMS)
      test(`${entry} ${variant} plays clean in the ${arm} arm`, async () => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          // agent-pane.transcript has no experiment of its own: the arm comes from the host override.
          await page.addInitScript((chosen) => {
            (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
              "background-turn-look": chosen,
            };
          }, arm);
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 900, reducedMotion: "true" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
            timeout: 120_000,
          });
          const state = await page.evaluate(() => ({
            ready: document.documentElement.dataset.galleryReady,
            play: document.documentElement.dataset.galleryPlay,
          }));
          expect(state).toEqual({ ready: "1", play: expect.not.stringMatching(/^fail$/) });
        } finally {
          await page.close();
        }
      });
});
