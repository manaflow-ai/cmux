// The composer's draft scrollbar runs in a lane between the draft and the actions, down to the
// box's bottom inset, as Claude desktop draws it (Leo 2026-11-22, his clip of Claude: "the thumb only
// appears when it's relevant ... AND IT ACTUALLY GOES IN A REASONABLE LOOKING PLACE, INSTEAD OF OUR
// THUMB THAT STOPS ATOP BUTTONS!? ... THEN OUR CALIBRATION OF "BOTTOM" LOOKS STUPID"). It ran down
// the box's right edge before, stopping a block inset over Send. It stays inside the box (Leo
// 2026-10-22: "claude indeed has it on the inside").
// In the gallery's `agent-pane.composer` long draft, Claude's look (the default), at three widths:
//   - the draft overflows and its scroller (the prompt field) ends at the actions' left edge, so the
//     scrollbar lane is the field's last 8 px, beside the mic and Send, never under them;
//   - the draft's text keeps clear of the mic and Send: it ends left of them;
//   - the mic and Send still take a click at their centre.
// And in the gallery's `agent-pane.composer-scrollbar` (the placements drawn for the pick): with the
// draft scrolled to its end, the drawn thumb ends level with the buttons' bottom in the shipped
// `lane` (within 3 px: the track's end inset is the buttons' own inset over the box's bottom edge),
// stops at least 8 px above Send in `edge`, and runs past Send's top in `edge-full`. The placements
// gallery marks the field scrolling, since the thumb shows only while the draft scrolls.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

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
    await warmGalleryFrame(vite, PLACEMENTS, { browser, params: { variant: "lane" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [420, 760, 1100])
    test(`at ${width} px the long draft's scrollbar runs in a lane beside the mic and Send`, async () => {
      const page = await browser!.newPage({ viewport: { width, height: 420 } });
      await page.goto(stageURL("long-draft"));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.evaluate(async () => {
        const source = "/gallery/src/agent-session/acpmux/composerLook.ts";
        const { setPreviewComposerLook } = await import(/* @vite-ignore */ source);
        setPreviewComposerLook("claude");
      });
      await page.locator('.acpmux-composer:not([data-composer-look="codex"]) .acpmux-md-field').waitFor();
      const drawn = await page.evaluate(
        ({ COMPOSER_MD_FIELD }) => {
          const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
          const field = document.querySelector<HTMLElement>(COMPOSER_MD_FIELD)!;
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
            // The lane ends where the actions start, inside the box (composerLocation.css).
            laneBesideActions:
              fieldRect.right <= left + 0.5 && fieldRect.right >= left - 12 && fieldRect.right < box.right,
            textClearOfActions: text.right <= left + 0.5,
            actions: actions.length,
            unreachable,
          };
        },
        { COMPOSER_MD_FIELD },
      );
      await page.close();
      expect(drawn.actions).toBeGreaterThanOrEqual(1);
      expect({
        overflows: drawn.overflows,
        laneBesideActions: drawn.laneBesideActions,
        textClearOfActions: drawn.textClearOfActions,
        unreachable: drawn.unreachable,
      }).toEqual({ overflows: true, laneBesideActions: true, textClearOfActions: true, unreachable: [] });
    });
  /// The lowest drawn row of the draft's thumb with the draft scrolled to its end, and Send's top.
  /// The box's last scroller-lane column is shot with the draft at its start and at its end: only the
  /// thumb moves between them (the box's rim and rounded corner stay), so the lowest row that differs
  /// is the bottom of the thumb at its end.
  async function thumbEnd(page: Page) {
    const geometry = await page.evaluate(
      ({ COMPOSER_MD_FIELD }) => {
        const field = document.querySelector<HTMLElement>(COMPOSER_MD_FIELD)!;
        const rect = field.getBoundingClientRect();
        const send = [
          ...document.querySelectorAll<HTMLElement>(".acpmux-composer-box .acpmux-composer-actions button"),
        ].filter((button) => button.offsetWidth > 0);
        const top = Math.min(...send.map((button) => button.getBoundingClientRect().top));
        const bottom = Math.max(...send.map((button) => button.getBoundingClientRect().bottom));
        return {
          sendBottom: bottom,
          x: Math.round(rect.right - 4),
          top: Math.round(rect.top),
          bottom: Math.round(rect.bottom),
          sendTop: top,
        };
      },
      { COMPOSER_MD_FIELD },
    );
    const column = async (to: "start" | "end") => {
      await page.evaluate(
        ({ to, COMPOSER_MD_FIELD }) => {
          const field = document.querySelector<HTMLElement>(COMPOSER_MD_FIELD)!;
          field.scrollTop = to === "end" ? field.scrollHeight : 0;
          return new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        },
        { to, COMPOSER_MD_FIELD },
      );
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
    return {
      thumbBottom: last < 0 ? undefined : geometry.top + last + 1,
      sendTop: geometry.sendTop,
      sendBottom: geometry.sendBottom,
    };
  }

  for (const variant of ["lane", "edge", "edge-full"] as const)
    test(`placement ${variant}: where the thumb ends against Send`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 420 } });
      await page.goto(stageURL(variant, PLACEMENTS));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(COMPOSER_MD_FIELD).waitFor();
      const end = await thumbEnd(page);
      await page.close();
      console.log(`THUMB_END ${variant} ${JSON.stringify(end)}`);
      expect(end.thumbBottom).toBeDefined();
      const bottom = end.thumbBottom!;
      if (variant === "lane") expect(Math.abs(bottom - end.sendBottom)).toBeLessThanOrEqual(3);
      else if (variant === "edge") expect(end.sendTop - bottom).toBeGreaterThanOrEqual(8);
      else expect(bottom).toBeGreaterThan(end.sendTop);
    });
});
