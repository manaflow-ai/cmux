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
// And in the gallery's `agent-pane.composer-scrollbar` (the placements drawn for the pick): with the
// draft scrolled to its end, the drawn thumb stops above Send in the shipped `edge`, and runs past
// Send's top in `edge-full` (so the probe sees the thumb at all).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
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
  const PLACEMENTS = "agent-pane.composer-scrollbar";
  const stageURL = (variant: string, entry = ENTRY) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "long-draft" } });
    await warmGalleryFrame(vite, PLACEMENTS, { browser, params: { variant: "edge" } });
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
          // The lane sits 2 px inside the box's hairline rim (composerLocation.css).
          laneOnBoxEdge: Math.abs(box.right - 2 - fieldRect.right) <= 1,
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
  /// The lowest drawn row of the draft's thumb with the draft scrolled to its end, and Send's top.
  /// The box's last scroller-lane column is shot with the draft at its start and at its end: only the
  /// thumb moves between them (the box's rim and rounded corner stay), so the lowest row that differs
  /// is the bottom of the thumb at its end.
  async function thumbEnd(page: Page) {
    const geometry = await page.evaluate(() => {
      const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field")!;
      const rect = field.getBoundingClientRect();
      const send = [
        ...document.querySelectorAll<HTMLElement>(".acpmux-composer-box .acpmux-composer-actions button"),
      ].filter((button) => button.offsetWidth > 0);
      const top = Math.min(...send.map((button) => button.getBoundingClientRect().top));
      return {
        x: Math.round(rect.right - 4),
        top: Math.round(rect.top),
        bottom: Math.round(rect.bottom),
        sendTop: top,
      };
    });
    const column = async (to: "start" | "end") => {
      await page.evaluate((to) => {
        const field = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field")!;
        field.scrollTop = to === "end" ? field.scrollHeight : 0;
        return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      }, to);
      return PNG.sync.read(
        await page.screenshot({
          clip: { x: geometry.x, y: geometry.top, width: 1, height: geometry.bottom - geometry.top },
        }),
      );
    };
    const start = await column("start");
    const end = await column("end");
    let last = -1;
    for (let y = 0; y < end.height; y++) {
      const at = y * end.width * 4;
      const diff = [0, 1, 2].reduce((sum, c) => sum + Math.abs(end.data[at + c]! - start.data[at + c]!), 0);
      if (diff > 24) last = y;
    }
    return { thumbBottom: last < 0 ? undefined : geometry.top + last + 1, sendTop: geometry.sendTop };
  }

  for (const [variant, aboveSend] of [
    ["edge", true],
    ["edge-full", false],
  ] as const)
    test(`placement ${variant}: the thumb ${aboveSend ? "stops above" : "runs past"} Send's top`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 420 } });
      await page.goto(stageURL(variant, PLACEMENTS));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(".acpmux-composer-box .acpmux-md-field").waitFor();
      const end = await thumbEnd(page);
      await page.close();
      expect(end.thumbBottom).toBeDefined();
      expect({ aboveSend: end.thumbBottom! <= end.sendTop }).toEqual({ aboveSend });
    });
});
