// A pane without the keyboard keeps its header tools quiet (Leo 2026-11-07: "does it make sense for, like, when
// you're not highlighted on a thing to still— when you're not focused on a pane, an agent pane, to still be able to
// highlight whatever's going on down there?"). The App marks such a page `data-page-inactive` (pageKey.ts); there an
// open panel's toggle draws no square and no lit ink at rest, and still lights on hover and while its menu is open.
// The focused pane keeps the square (#32687). Also: the tools the page reports to the tab row are exactly their
// visible buttons, so the row keeps no empty slot for a hidden one (the ghost fifth icon).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-header-unfocused-pane.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const read = (file: string) => fs.readFileSync(path.join(source, file), "utf8");
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 1, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const MUTED = "rgb(150, 160, 170)";
  const LIT = "rgb(210, 130, 90)";
  const ON = "rgb(4, 5, 6)";
  const NONE = "rgba(0, 0, 0, 0)";

  for (const [name, focused, state, expected] of [
    ["focused pane, open toggle at rest", true, "rest", { background: ON, glyph: LIT }],
    ["unfocused pane, open toggle at rest", false, "rest", { background: NONE, glyph: MUTED }],
    ["unfocused pane, open toggle hovered", false, "hover", { background: ON, glyph: LIT }],
    ["unfocused pane, open toggle holding its menu", false, "popup-open", { background: ON, glyph: LIT }],
  ] as const) {
    test(`${name}: ${expected.background === NONE ? "no square" : "the square"}`, async () => {
      const css = [
        read("agent-session/shared/styles.css"),
        read("agent-session/acpmux/styles.css"),
        read("agent-session/acpmux/header/header.css"),
      ].join("\n");
      const page = await browser.newPage({ viewport: { width: 320, height: 120 } });
      try {
        await page.setContent(`<!doctype html><html${focused ? "" : " data-page-inactive"}><head><style>
          ${css}
          :root { --agent-text: rgb(240, 240, 240); --agent-muted: ${MUTED}; --agent-soft: rgb(100, 110, 120);
                  --agent-lit-glyph: ${LIT}; --acpmux-motion-hover: 0ms; --agent-page-bg: rgb(20, 30, 40);
                  --acpmux-header-tool-hover: rgb(1, 2, 3); --acpmux-header-tool-on: ${ON}; }
        </style></head><body>
          <section class="acpmux-shell" data-tab-row style="--acpmux-tab-row-height:40px"><div class="acpmux-stage">
            <header class="acpmux-header" data-tab-row><div class="acpmux-handoff-header-tools"><div class="acpmux-header-tools">
              <button class="acpmux-header-tool" aria-label="Session Info" aria-pressed="true">
                <span class="acpmux-header-symbol acpmux-header-glyph" style="width:16px;height:16px;color:var(--agent-lit-glyph, var(--agent-accent))"></span>
              </button>
            </div></div></header>
          </div></section>
        </body></html>`);
        const button = page.locator(".acpmux-header-tool");
        await page.mouse.move(319, 119);
        if (state === "hover") await button.hover();
        if (state === "popup-open") await button.evaluate((node) => node.setAttribute("data-popup-open", ""));
        const computed = await button.evaluate((node) => ({
          background: getComputedStyle(node).backgroundColor,
          glyph: getComputedStyle(node.firstElementChild!).color,
        }));
        expect(computed).toEqual(expected);
      } finally {
        await page.close();
      }
    });
  }

  test("the tools the page reports to the tab row are exactly its visible buttons", async () => {
    const page = await pane.open({ width: 900, height: 640 });
    try {
      await page.evaluate(async () => {
        const url = "/header/tabRow.ts";
        const module = (await import(/* @vite-ignore */ url)) as {
          setTabRow(value: { height: number; trailingInset: number }): void;
        };
        module.setTabRow({ height: 40, trailingInset: 8 });
      });
      await page.waitForFunction(() => document.querySelector("section.acpmux-shell")?.hasAttribute("data-tab-row"));
      const measured = await page.evaluate(() => {
        const reported = document.querySelector<HTMLElement>(".acpmux-handoff-header-tools")!;
        const flat = (element: Element): Element[] =>
          getComputedStyle(element).display === "contents" ? [...element.children].flatMap(flat) : [element];
        const row = (element: HTMLElement) => {
          const children = [...element.children]
            .filter((child) => getComputedStyle(child).display !== "none")
            .flatMap(flat);
          const gap = Number.parseFloat(getComputedStyle(element).columnGap) || 0;
          return {
            empty: children
              .filter((child) => child.getBoundingClientRect().width === 0)
              .map((child) => child.className),
            sum:
              children.reduce((width, child) => width + child.getBoundingClientRect().width, 0) +
              gap * Math.max(0, children.length - 1),
            width: element.getBoundingClientRect().width,
          };
        };
        const header = document.querySelector<HTMLElement>("header.acpmux-header")!;
        return {
          outer: row(reported),
          tools: row(document.querySelector<HTMLElement>(".acpmux-header-tools")!),
          inset: Math.round(header.getBoundingClientRect().right - reported.getBoundingClientRect().right),
        };
      });
      expect(measured.outer.empty).toEqual([]);
      expect(measured.tools.empty).toEqual([]);
      expect(Math.abs(measured.outer.width - measured.outer.sum)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(measured.tools.width - measured.tools.sum)).toBeLessThanOrEqual(0.5);
      // The tools end the offered inset from the pane's edge: the native toolbar's width, nothing more.
      expect(measured.inset).toBe(8);
    } finally {
      await page.close();
    }
  });
});
