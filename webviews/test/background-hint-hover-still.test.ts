// l10n-allow-file: the gallery fixture supplies the transcript's commands.
// Leo, 2026-11-06, hovering the agent chat's right edge over a running command's live line: "this
// flickers". The line read "8s · 2m5 1.4K toke": its "⌃B to run in background" took its room only on
// hover, squeezing the times and tokens over each other and moving them under the pointer. The hint
// keeps its room while it is offered (backgroundHintRoom.experiment.ts), so pointing at the line
// fades it in and every time and count keeps its box, with no two drawn over each other.
//
// Real Chromium from Playwright on the gallery scene `agent-pane.background-hint`, variant
// "long-hovered" (a long command, its own time, the turn's time and its tokens).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { CLOCK_ON_LINE, pinArms } from "./support/pinArms";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-hint-hover-still.test.ts", async () => {
  const ENTRY = "agent-pane.background-hint";
  const VARIANT = "long-hovered";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("background-hint-hover-still: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const LINE = ".cv-worked.is-below";

  for (const width of [900, 560])
    test(`at ${width}px, hovering a running command's live line moves and overlaps none of its counts`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width, height: 360 } });
      // The line keeps the turn's time and tokens, which this file checks for overlap.
      await pinArms(page, CLOCK_ON_LINE);
      await page.addInitScript(() => localStorage.clear());
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
      await page.locator(`${LINE} .cv-command__bg`).waitFor({ state: "attached", timeout: 30_000 });
      await page.locator(`${LINE} .cv-worked__count`).last().waitFor({ timeout: 30_000 });
      const read = () =>
        page.evaluate((line) => {
          const node = document.querySelector<HTMLElement>(line)!;
          const boxes = [
            ...node.querySelectorAll<HTMLElement>(".cv-worked__time, .cv-worked__own, .cv-worked__count"),
          ].map((each) => {
            // Where its words draw, which spill past a squeezed box.
            const range = document.createRange();
            range.selectNodeContents(each);
            const words = range.getBoundingClientRect();
            return { text: each.textContent, left: Math.round(words.left), right: Math.round(words.right) };
          });
          return { boxes, hint: getComputedStyle(node.querySelector(".cv-command__bg")!).opacity };
        }, LINE);
      const before = await read();
      expect(before.hint).toBe("0");
      expect(before.boxes.length).toBeGreaterThanOrEqual(2);
      // At the line's right edge, where Leo pointed.
      const box = (await page.locator(LINE).boundingBox())!;
      await page.mouse.move(box.x + box.width - 4, box.y + box.height / 2);
      await page.waitForFunction(
        (line) => getComputedStyle(document.querySelector<HTMLElement>(`${line} .cv-command__bg`)!).opacity === "1",
        LINE,
      );
      const after = await read();
      expect(after.boxes).toEqual(before.boxes);
      for (let index = 1; index < after.boxes.length; index++)
        expect({
          at: after.boxes[index]!.text,
          overlap: after.boxes[index]!.left < after.boxes[index - 1]!.right,
        }).toEqual({
          at: after.boxes[index]!.text,
          overlap: false,
        });
      await page.close();
    });
});
