// In the card and tree looks a run's steps are split by hairlines (conversation.css `.cv-step +
// .cv-step`). A windowed run draws a box for the steps it leaves out (stepWindow.tsx), and when
// that box would flip the zebra rows' parity it adds a zero-height pad after it. The pad has the
// box's class, `cv-steps__rest`, so the first step drawn after either one keeps its hairline
// (`.cv-steps__rest + .cv-step`). This pins that in a real engine. The reader opens the run with a
// click and scrolls its box with the wheel, through every step, in both looks.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("tool-group-step-hairline.test.ts", async () => {
  const ENTRY = "agent-pane.tool-group-size";
  const ROW = '[data-row-id="tool-group-size-run"]';
  setDefaultTimeout(300_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "n100" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const look of ["card", "tree"] as const)
    for (const variant of ["n100", "mixed-commands"] as const)
      test(`${look}, ${variant}: the first step drawn after a windowed box or its pad keeps its hairline`, async () => {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
        try {
          await installPaintedFrames(page);
          await page.addInitScript(() => localStorage.clear());
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
          await page.locator(`${ROW} button[data-tool-group]`).waitFor();
          // The look after the gallery has applied its own document attributes.
          await page.evaluate((look) => document.documentElement.setAttribute("data-tool-steps-look", look), look);
          const group = page.locator(`${ROW} button[data-tool-group]`);
          await group.click();
          const box = page.locator(`${ROW} .cv-run-scroll`);
          await box.waitFor();
          // The fold over: the opened body's `.cv-fold` (an ancestor of the items, not their parent)
          // no longer clips, and nothing under it still animates.
          await page.waitForFunction((row) => {
            const fold = document.querySelector(`${row} [data-tool-group-items]`)?.closest(".cv-fold");
            return (
              !!fold &&
              !fold.hasAttribute("data-fold-clip") &&
              fold.getAnimations({ subtree: true }).every((each) => each.playState !== "running")
            );
          }, ROW);
          const corner = (await box.boundingBox())!;
          // Near the box's top-left: the floating jump-to-latest button can sit over its centre.
          await page.mouse.move(corner.x + 12, corner.y + 12);
          const seen = { rest: 0, pad: 0, step: 0, bare: [] as string[] };
          for (let notch = 0; notch < 200; notch++) {
            const frame = await box.evaluate(async (node) => {
              // Read once the wheel's frame has painted.
              await window.cmuxPaintFrame();
              const found = { rest: 0, pad: 0, step: 0, bare: [] as string[] };
              for (const step of node.querySelectorAll<HTMLElement>(".cv-steps > .cv-step")) {
                const before = step.previousElementSibling;
                if (!before) continue;
                // A box and its pad by what they hold (the steps they stand in for), not by the class
                // the rule matches, so a pad that lost the class shows as a step with no hairline.
                const kind = before.hasAttribute("data-steps-rest")
                  ? "rest"
                  : before.hasAttribute("data-rest-from")
                    ? "pad"
                    : before.classList.contains("cv-step")
                      ? "step"
                      : undefined;
                if (!kind) continue;
                found[kind] += 1;
                const style = getComputedStyle(step);
                if (style.borderTopStyle !== "solid" || parseFloat(style.borderTopWidth) <= 0)
                  found.bare.push(`${kind}:${step.dataset.step ?? step.dataset.stepCall}`);
              }
              return { ...found, end: node.scrollTop + node.clientHeight >= node.scrollHeight - 1 };
            });
            seen.rest += frame.rest;
            seen.pad += frame.pad;
            seen.step += frame.step;
            seen.bare.push(...frame.bare);
            if (frame.end) break;
            await page.mouse.wheel(0, 60);
          }
          // The scroll passed boxes and pads both, so each case was seen.
          expect(seen.rest).toBeGreaterThan(0);
          expect(seen.pad).toBeGreaterThan(0);
          expect(seen.step).toBeGreaterThan(0);
          expect(seen.bare).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
