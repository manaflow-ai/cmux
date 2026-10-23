// The composer's draft scrollbar sits on the box's own right edge (Leo 2026-10-22: "shouldn't the
// styling wrt composer vs the chat/window (these should be one and hte same) be more cohesive? well
// idk but the chatgpt(codex) has it on the outside while claude indeed has it on the inside"). The
// chat's thin thumb runs down the pane's right edge; the composer's runs down the box's, as in Claude
// desktop and as Codex's look already draws it, not down a lane between the draft and Send.
// In the gallery's `agent-pane.composer` long draft, Claude's look (the default), at three widths:
//   - the draft overflows and its scroller (the prompt field) ends on the box's right edge, so the
//     scrollbar lane is the box's last 8 px;
//   - the draft's text keeps clear of the mic and Send: it ends left of them;
//   - the mic and Send still take a click at their centre.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-scrollbar-edge.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-scrollbar-edge: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer scrollbar edge", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.composer";
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "long-draft" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [420, 760, 1100])
    test(`at ${width} px the long draft's scrollbar runs down the box's right edge`, async () => {
      const page = await browser!.newPage({ viewport: { width, height: 420 } });
      await page.goto(stageURL("long-draft"));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(".acpmux-composer-box .acpmux-md-field").waitFor();
      const drawn = await page.evaluate(() => {
        const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field")!;
        const fieldRect = field.getBoundingClientRect();
        const text = field.querySelector(".ProseMirror")!.getBoundingClientRect();
        const actions = [
          ...document.querySelectorAll<HTMLElement>(".acpmux-composer-box .acpmux-composer-actions button"),
        ].filter((button) => button.offsetWidth > 0);
        const left = Math.min(...actions.map((button) => button.getBoundingClientRect().left));
        const unreachable = actions
          .filter((button) => {
            const rect = button.getBoundingClientRect();
            const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
            return !hit || !(hit === button || button.contains(hit));
          })
          .map((button) => button.getAttribute("aria-label") ?? button.className);
        return {
          overflows: field.scrollHeight > field.clientHeight + 1,
          laneOnBoxEdge: Math.abs(box.right - fieldRect.right) <= 1,
          gap: Math.round(box.right - fieldRect.right),
          textClearOfActions: text.right <= left + 0.5,
          actions: actions.length,
          unreachable,
        };
      });
      await page.close();
      expect(drawn.actions).toBeGreaterThanOrEqual(1);
      expect({
        overflows: drawn.overflows,
        laneOnBoxEdge: drawn.laneOnBoxEdge,
        textClearOfActions: drawn.textClearOfActions,
        unreachable: drawn.unreachable,
      }).toEqual({ overflows: true, laneOnBoxEdge: true, textClearOfActions: true, unreachable: [] });
    });
});
