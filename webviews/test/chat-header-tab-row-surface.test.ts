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
      // Plain in every state: no plate at rest, on hover, with its menu open, focused, disabled or pressed
      // (Leo, 2026-10-31: "AND THE FUCKING BACKGROUND ON THIS FUCKING BUILD ON THESE BUTTONS STILL ISN'T
      // FUCKING REMOVESD"). Pressed (its panel open), it reads as on by the lit ink alone, as the App's pane
      // toolbar toggles do (Leo, 2026-10-29: "i literally meant the ui depicting it as toggled or not").
      test(`${host} keeps plain icons in its ${state} state`, async () => {
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
          // Hovering an open panel's toggle keeps its lit ink and gains no fill.
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
          expect(computed).toMatchObject({
            background: "rgba(0, 0, 0, 0)",
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

  test("the loading shell carries the offered row state before the handshake", () => {
    const app = read("agent-session/acpmux/App.tsx");
    const loading = app.match(/const pane = !knowsWhatItIs \? \(([\s\S]*?)\) : \(/)?.[1] ?? "";
    expect(loading).toContain('data-tab-row={inTabRow ? "" : undefined}');
    expect(loading).toContain("style={inTabRow ? tabRowStyle(tabRow) : undefined}");
  });
});
