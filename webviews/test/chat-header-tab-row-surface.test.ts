import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-header-tab-row-surface.test.ts", async () => {
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

  test("the normal App shell carries the offered row state", async () => {
    const page = await pane.open({ width: 900, height: 640 });
    try {
      await page.evaluate(async () => {
        const url = "/header/tabRow.ts";
        const module = (await import(/* @vite-ignore */ url)) as {
          setTabRow(value: { height: number; trailingInset: number }): void;
        };
        module.setTabRow({ height: 40, trailingInset: 12 });
      });
      const shell = page.locator("section.acpmux-shell").first();
      await page.waitForFunction(() => document.querySelector("section.acpmux-shell")?.hasAttribute("data-tab-row"));
      const rendered = await shell.evaluate((node) => ({
        tabRow: node.hasAttribute("data-tab-row"),
        height: getComputedStyle(node).getPropertyValue("--acpmux-tab-row-height"),
        inset: getComputedStyle(node).getPropertyValue("--acpmux-tab-row-inset"),
      }));
      expect(rendered).toEqual({ tabRow: true, height: "40px", inset: "12px" });
    } finally {
      await page.close();
    }
  });

  test("a separate header fits its tools without an empty vertical band", async () => {
    const page = await pane.open({ width: 900, height: 640 });
    try {
      const header = page.locator("header.acpmux-header");
      const box = (await header.boundingBox())!;
      const tools = (await page.locator(".acpmux-header-tools").boundingBox())!;
      expect(box.height).toBe(28);
      expect(tools.height).toBe(24);
      expect(tools.y - box.y).toBe(2);
    } finally {
      await page.close();
    }
  });

  // Every pane header that draws these buttons: the floating chat's header and folded bar, the chat
  // header's own row, and the chat header sharing the pane's tab row (chrome.tabs.rowTools, on by default).
  const hosts = {
    "acpmux-floating-header": (button: string) => `<header class="acpmux-floating-header">${button}</header>`,
    "acpmux-floating-bar": (button: string) => `<header class="acpmux-floating-bar">${button}</header>`,
    "acpmux-header-tools": (button: string) => `<header class="acpmux-header-tools">${button}</header>`,
    "acpmux-header-tools in the tab row": (button: string) =>
      `<section class="acpmux-shell" data-tab-row style="--acpmux-tab-row-height:40px">` +
      `<div class="acpmux-stage"><header class="acpmux-header" data-tab-row><div class="acpmux-handoff-header-tools">` +
      `<div class="acpmux-header-tools">${button}</div></div></header></div></section>`,
  } as const;
  for (const [host, wrap] of Object.entries(hosts)) {
    for (const state of [
      "rest",
      "hover",
      "pressed",
      "pressed-hover",
      "popup-open",
      "focus-visible",
      "disabled",
    ] as const) {
      // Nothing behind an icon at rest, focused or disabled; the hover pill only under the pointer; the filled
      // rounded square only while its panel or menu is open (Leo, 2026-11-02: "FOR THE FUCKING STUPID BACKGROUND
      // ON THE FUCKING TOP RIGHT ICONS TO BE REMOVED"; his reference fills only the toggled-on button). Pressed
      // (its panel open), the glyph also takes the lit ink, as the App's pane toolbar toggles do (Leo, 2026-10-29:
      // "i literally meant the ui depicting it as toggled or not").
      test(`${host} draws no background behind its icons in its ${state} state`, async () => {
        // Match the shipped cascade: the shared pane sheet supplies the important focus gradient.
        const shellCss = [
          read("agent-session/shared/styles.css"),
          read("agent-session/acpmux/styles.css"),
          read("agent-session/acpmux/header/header.css"),
        ].join("\n");
        const page = await browser.newPage({ viewport: { width: 320, height: 120 } });
        try {
          await page.setContent(`<!doctype html><html><head><style>
            ${shellCss}
            :root {
              --agent-text: rgb(240, 240, 240); --agent-muted: rgb(150, 160, 170);
              --agent-soft: rgb(100, 110, 120); --agent-accent: rgb(200, 120, 80);
              --agent-lit-glyph: rgb(210, 130, 90);
              --acpmux-motion-hover: 0ms; --cmux-selection: rgba(255, 255, 255, 0.12);
              --agent-page-bg: rgb(20, 30, 40);
              --acpmux-header-tool-hover: rgb(1, 2, 3); --acpmux-header-tool-on: rgb(4, 5, 6);
            }
          </style></head><body>
            ${wrap(`<button class="acpmux-header-tool" aria-label="Panel">
              <span class="acpmux-header-symbol" style="width:16px;height:16px"></span>
            </button>`)}
          </body></html>`);
          const button = page.locator(".acpmux-header-tool");
          await page.mouse.move(319, 119);
          if (state === "hover") await button.hover();
          if (state === "pressed" || state === "pressed-hover") {
            await button.evaluate((node) => {
              node.setAttribute("aria-pressed", "true");
              // HeaderIcon(selected) supplies the lit ink on the glyph, not the button's surface.
              (node.firstElementChild as HTMLElement).style.color = "var(--agent-lit-glyph, var(--agent-accent))";
            });
          }
          // Hovering an open panel's toggle keeps its lit ink and its on fill.
          if (state === "pressed-hover") await button.hover();
          if (state === "popup-open") await button.evaluate((node) => node.setAttribute("data-popup-open", ""));
          if (state === "focus-visible") {
            await page.keyboard.press("Tab");
            expect(await button.evaluate((node) => node.matches(":focus-visible"))).toBe(true);
          }
          if (state === "disabled") await button.evaluate((node) => ((node as HTMLButtonElement).disabled = true));
          const computed = await button.evaluate((node) => {
            const style = getComputedStyle(node);
            return {
              background: style.backgroundColor,
              image: style.backgroundImage,
              color: style.color,
              outline: style.outlineStyle,
              outlineWidth: style.outlineWidth,
              shadow: style.boxShadow,
              glyph: getComputedStyle(node.firstElementChild!).color,
            };
          });
          const color =
            state === "disabled"
              ? "rgb(100, 110, 120)"
              : state === "pressed" || state === "pressed-hover"
                ? "rgb(210, 130, 90)"
                : state === "hover" || state === "popup-open"
                  ? "rgb(240, 240, 240)"
                  : "rgb(150, 160, 170)";
          const background =
            state === "pressed" || state === "pressed-hover" || state === "popup-open"
              ? "rgb(4, 5, 6)"
              : state === "hover"
                ? "rgb(1, 2, 3)"
                : "rgba(0, 0, 0, 0)";
          expect(computed).toMatchObject({
            background,
            image: "none",
            color,
            outline: state === "focus-visible" ? "solid" : "none",
            shadow: "none",
            glyph: color,
          });
          if (state === "focus-visible") {
            expect(parseFloat(computed.outlineWidth)).toBeGreaterThan(0);
            expect(parseFloat(computed.outlineWidth)).toBeLessThanOrEqual(1.5);
          }
        } finally {
          await page.close();
        }
      });
    }
  }

  // The tools in the tab row sit on the row's own surface, as the tabs do: the shell paints no band of the page's
  // color behind them, only below the row (Leo, 2026-11-02: "FOR THE FUCKING STUPID BACKGROUND ON THE FUCKING TOP
  // RIGHT ICONS TO BE REMOVED").
  test("the tab row shell paints nothing behind the tools", async () => {
    const shellCss = [
      read("styles.css"),
      read("agent-session/shared/styles.css"),
      read("agent-session/acpmux/styles.css"),
      read("agent-session/acpmux/header/header.css"),
    ].join("\n");
    const page = await browser.newPage({ viewport: { width: 320, height: 120 } });
    try {
      // The native row under the page is green; the page's own color is red.
      await page.setContent(`<!doctype html><html style="background:rgb(0,255,0)"><head><style>
        ${shellCss}
        :root { --agent-page-bg: rgb(255, 0, 0); --agent-muted: rgb(150, 160, 170); }
        html:has(.acpmux-shell[data-tab-row]) { background: rgb(0, 255, 0) !important; }
        body { margin: 0; height: 120px; }
      </style></head><body>
        <section class="acpmux-shell" data-tab-row style="--acpmux-tab-row-height:40px;height:120px">
          <div class="acpmux-stage" style="flex:1;display:flex;flex-direction:column">
            <header class="acpmux-header" data-tab-row><div class="acpmux-handoff-header-tools">
              <div class="acpmux-header-tools"><button class="acpmux-header-tool" aria-label="Panel"></button></div>
            </div></header>
          </div>
        </section>
      </body></html>`);
      const shot = await page.screenshot({ type: "png" });
      const { PNG } = await import("pngjs");
      const png = PNG.sync.read(shot);
      const at = (x: number, y: number) => {
        const i = (png.width * y + x) * 4;
        return [png.data[i], png.data[i + 1], png.data[i + 2]];
      };
      // Behind the tools (inside the 40px row): the row's green. Below the row: the page's red.
      expect(at(300, 10)).toEqual([0, 255, 0]);
      expect(at(10, 20)).toEqual([0, 255, 0]);
      expect(at(10, 80)).toEqual([255, 0, 0]);
    } finally {
      await page.close();
    }
  });

  test("the loading shell carries the offered row state before the handshake", () => {
    const app = read("agent-session/acpmux/App.tsx");
    const loading = app.match(/const pane = !knowsWhatItIs \? \(([\s\S]*?)\) : \(/)?.[1] ?? "";
    expect(loading).toContain('data-tab-row={inTabRow ? "" : undefined}');
    expect(loading).toContain("style={inTabRow ? tabRowStyle(tabRow) : undefined}");
  });
});
