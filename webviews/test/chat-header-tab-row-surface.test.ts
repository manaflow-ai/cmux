import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { PNG } from "pngjs";
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

  test("the shipped tab-row shell leaves the native strip transparent", async () => {
    const page = await browser.newPage({ viewport: { width: 240, height: 100 } });
    // This is the stylesheet that build-agent-pane-web.sh inlines into the shipped agent pane.
    // webviews/src/styles.css belongs to the page host and is deliberately not part of this fixture.
    const shellCss = [read("agent-session/acpmux/styles.css"), read("agent-session/acpmux/header/header.css")].join(
      "\n",
    );
    await page.setContent(`<!doctype html><html><head><style>
      html, body { width: 100%; height: 100%; margin: 0; background: rgb(10, 20, 30); }
      ${shellCss}
    </style></head><body>
      <section class="acpmux-shell" data-tab-row
        style="--acpmux-tab-row-height:40px;--agent-page-bg:rgb(200,10,20)">
        <header class="acpmux-header" data-tab-row><div id="tools"></div></header>
      </section>
    </body></html>`);
    const shot = PNG.sync.read(await page.screenshot());
    const pixel = (x: number, y: number) => {
      const offset = (y * shot.width + x) * 4;
      return Array.from(shot.data.subarray(offset, offset + 4));
    };
    // Every pixel in the offered row, including its bottom edge, is the native strip beneath it.
    expect(pixel(20, 8)).toEqual([10, 20, 30, 255]);
    expect(pixel(20, 39)).toEqual([10, 20, 30, 255]);
    // The page fill starts immediately after the offered row.
    expect(pixel(20, 50)).toEqual([200, 10, 20, 255]);
    expect(await page.locator(".acpmux-header").evaluate((node) => getComputedStyle(node, "::after").content)).toBe(
      "none",
    );
    await page.close();
  });

  for (const host of ["acpmux-floating-header", "acpmux-floating-bar", "acpmux-header-tools"]) {
    for (const state of [
      "rest",
      "hover",
      "pressed",
      "pressed-hover",
      "popup-open",
      "focus-visible",
      "disabled",
    ] as const) {
      // Plain at rest, on hover, with its menu open, focused or disabled. Pressed (its panel open), it
      // takes the App's toolbar selection fill on its own square (Leo, 2026-10-29: "i literally meant the
      // ui depicting it as toggled or not").
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
              --acpmux-motion-hover: 0ms; --cmux-selection: rgba(255, 255, 255, 0.12);
            }
          </style></head><body>
            <header class="${host}"><button class="acpmux-header-tool" aria-label="Panel">
              <span class="acpmux-header-symbol" style="width:16px;height:16px"></span>
            </button></header>
          </body></html>`);
          const button = page.locator(".acpmux-header-tool");
          await page.mouse.move(319, 119);
          if (state === "hover") await button.hover();
          if (state === "pressed" || state === "pressed-hover") {
            await button.evaluate((node) => {
              node.setAttribute("aria-pressed", "true");
              // HeaderIcon(selected) supplies accent ink on the glyph, not the button's surface.
              (node.firstElementChild as HTMLElement).style.color = "var(--agent-accent)";
            });
          }
          // Hovering an open panel's toggle keeps its fill.
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
              : state === "hover" || state === "pressed" || state === "pressed-hover" || state === "popup-open"
                ? "rgb(240, 240, 240)"
                : "rgb(150, 160, 170)";
          expect(computed).toMatchObject({
            background:
              state === "pressed" || state === "pressed-hover" ? "rgba(255, 255, 255, 0.12)" : "rgba(0, 0, 0, 0)",
            image: "none",
            color,
            outline: state === "focus-visible" ? "solid" : "none",
            shadow: "none",
            glyph: state === "pressed" || state === "pressed-hover" ? "rgb(200, 120, 80)" : color,
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
