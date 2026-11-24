// The model menus' Harness updates footer (HarnessUpdates.tsx) sits on the menu's own insets.
// Lawrence, 2026-11-23 (msg 48182, a 3.04 PM capture of the columns menu: Claude Code and its Update
// under "GPT-5.6 Sol"): "spacing here is bad". Its one 20 px button sat 4 px under the divider and
// 8 px over the menu's bottom, the mark 12 px in and the button 8 px from the end.
//
// Measured in both lane engines on the columns menu (agent-pane.model-picker, quick-harness-update)
// and on a list menu's panel (agent-pane.harness-updates, one row and three):
// - each footer row is a menu row's height (--ui-row-height);
// - the buttons sit one inset from the divider, the menu's bottom and the menu's end: a 20 px control
//   centered in a primary row (--ds-control-primary - --ds-control-icon, halved), so the button is
//   centered with an even end inset and nothing pads the bottom past it;
// - the divider runs the menu's whole width, as the columns' other rules do;
// - the mark (or the heading's words) starts where a model row's content does: the menu's padding
//   plus a row's (--ui-popup-padding + --ui-row-padding-inline).
// cmux-web-test-timeout: 600
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("harness-updates-footer-insets.browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  const TOLERANCE = 0.75;
  const STATES = [
    { entry: "agent-pane.model-picker", variant: "quick-harness-update", width: 560, height: 560 },
    { entry: "agent-pane.harness-updates", variant: "one-harness", width: 360, height: 260 },
    { entry: "agent-pane.harness-updates", variant: "three-harnesses", width: 360, height: 260 },
  ] as const;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("harness updates footer insets", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    for (const state of STATES)
      await warmGalleryFrame(vite, state.entry, {
        browser: browsers.get("chromium")!,
        params: { variant: state.variant },
      });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Box = { top: number; bottom: number; left: number; right: number };
  type Measured = {
    popup: Box;
    section: Box;
    rows: { box: Box; lead: number; button: Box | null; reveal: Box | null }[];
    hairline: number;
    rowHeight: number;
    inset: number;
    lead: number;
  };

  const measure = async (engine: string, state: (typeof STATES)[number]): Promise<Measured> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({
      viewport: { width: state.width + 80, height: state.height + 80 },
      deviceScaleFactor: 2,
    });
    try {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(state.entry, { variant: state.variant, frame: "component", width: state.width })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.waitForSelector(".acpmux-harness-updates", { timeout: 30_000 });
      return await page.evaluate(() => {
        const box = (node: Element): Box => {
          const { top, bottom, left, right } = node.getBoundingClientRect();
          return { top, bottom, left, right };
        };
        const section = document.querySelector(".acpmux-harness-updates")!;
        const popup = section.closest(".acpmux-cols, .acpmux-quick-menu")!;
        // The menu's own lengths, read where its rows read them.
        const probe = (css: string) => {
          const node = document.createElement("div");
          node.style.cssText = `position:absolute;visibility:hidden;height:0;${css}`;
          popup.append(node);
          const width = node.getBoundingClientRect().width;
          node.remove();
          return width;
        };
        const rows = [...section.querySelectorAll(".acpmux-harness-updates-head, .acpmux-harness-update")].map(
          (row) => {
            const first = row.matches(".acpmux-harness-updates-head")
              ? row.querySelector(".acpmux-harness-updates-title")!
              : row.firstElementChild!;
            const button = row.querySelector("[data-default]");
            const reveal = row.querySelector("[data-reveal]");
            return {
              box: box(row),
              lead: first.getBoundingClientRect().left,
              button: button ? box(button) : null,
              reveal: reveal ? box(reveal) : null,
            };
          },
        );
        return {
          popup: box(popup),
          section: box(section),
          hairline: parseFloat(getComputedStyle(section).borderTopWidth) || 0,
          rows,
          rowHeight: probe("width:var(--ui-row-height)"),
          inset: probe("width:calc((var(--ds-control-primary) - var(--ds-control-icon)) / 2)"),
          lead: probe("width:calc(var(--ui-popup-padding) + var(--ui-row-padding-inline))"),
        };
      });
    } finally {
      await page.close();
    }
  };

  const near = (actual: number, expected: number) => Math.abs(actual - expected) <= TOLERANCE;

  for (const engine of ["chromium", "webkit"] as const)
    for (const state of STATES) {
      const name = `${engine} ${state.entry}/${state.variant}`;
      test(`${name}: the footer is menu rows on the menu's insets`, async () => {
        const m = await measure(engine, state);
        expect(m.rows.length).toBeGreaterThan(0);
        expect(m.rowHeight).toBeGreaterThan(0);
        expect(m.inset).toBeGreaterThan(0);
        const wrong: string[] = [];
        if (!near(m.section.left, m.popup.left) || !near(m.section.right, m.popup.right))
          wrong.push(`divider spans ${m.section.left}..${m.section.right}, menu ${m.popup.left}..${m.popup.right}`);
        const buttons = m.rows.filter((row) => row.button);
        if (buttons.length !== 1) wrong.push(`${buttons.length} filled buttons`);
        m.rows.forEach((row, index) => {
          const height = row.box.bottom - row.box.top;
          if (!near(height, m.rowHeight)) wrong.push(`row ${index} is ${height}px, a menu row ${m.rowHeight}px`);
          if (!near(row.lead - m.popup.left, m.lead))
            wrong.push(`row ${index} starts ${row.lead - m.popup.left}px in, a model row's content ${m.lead}px`);
          for (const button of [row.button, row.reveal])
            if (button && !near(m.popup.right - button.right, m.inset))
              wrong.push(`row ${index}'s button is ${m.popup.right - button.right}px from the end; inset ${m.inset}`);
        });
        const first = m.rows[0]!.button ?? m.rows[0]!.reveal;
        const last = m.rows.at(-1)!.button ?? m.rows.at(-1)!.reveal;
        if (!first || !last) wrong.push("a footer row without its button");
        else {
          const above = first.top - (m.section.top + m.hairline);
          const below = m.popup.bottom - last.bottom;
          if (!near(above, m.inset)) wrong.push(`${above}px from the divider to the first button; inset ${m.inset}`);
          if (!near(below, m.inset)) wrong.push(`${below}px from the last button to the bottom; inset ${m.inset}`);
        }
        expect(wrong).toEqual([]);
      });
    }
});
