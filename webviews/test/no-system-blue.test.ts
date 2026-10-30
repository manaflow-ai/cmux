// No system blue on our pages (cx-wqn5): the Increase Contrast focus ring is the theme accent the
// host fitted to the page's surfaces, text selection is the accent's tint, and the agent pane's
// pressed toggles use the accent rather than the theme's ANSI blue.
//
// The page is the real stylesheets with the variables the host sets (Rose Pine with the theme
// accent, its ANSI blue as the pane's highlight). The engines come from
// `playwright install chromium webkit`; where they are not installed, the cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("no-system-blue.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const read = (files: string[]) => files.map((file) => fs.readFileSync(path.join(source, file), "utf8")).join("\n");
  const pageCss = read(["pages/shared/desktop.css"]);
  const paneCss = read([
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
  ]);
  // Send in a composer, with every sheet that styles it (iMessage's blue sheet included, which the
  // composer still loads for other surfaces).
  const sendCss = read([
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "theme/messages.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/composerStates.css",
    "agent-session/acpmux/composerLocation.css",
    "agent-session/acpmux/newtab/screen.css",
  ]);

  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`no-system-blue: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  const IRIS = "rgb(196, 167, 231)";
  const PINE_BLUE = "rgb(49, 116, 143)";
  // The app window's ring, fitted to the app's surfaces rather than the page's: the page prefers its own accent.
  const APP_RING = "rgb(235, 188, 186)";
  const HOST = `--cmux-text:rgb(224,222,244);--cmux-accent:${IRIS};--cmux-app-focus-ring:${APP_RING};--agent-text:rgb(224,222,244);--agent-accent:${IRIS};--agent-highlight:${PINE_BLUE}`;
  const page = (css: string, body: string) =>
    `<!doctype html><html style="${HOST}"><head><style>${css}</style></head><body style="background:rgb(25,23,36)">${body}</body></html>`;

  for (const [name, engine] of engines) {
    describe(`no system blue in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      test("under Increase Contrast the focus ring is the theme accent", async () => {
        const tab = await browser.newPage();
        await tab.emulateMedia({ contrast: "more" });
        await tab.setContent(page(pageCss, `<button id="button">Done</button>`));
        await tab.keyboard.press("Tab");
        const ring = await tab.$eval("#button", (node) => getComputedStyle(node).outlineColor);
        expect(ring).toBe(IRIS);
        await tab.close();
      });

      test("text selection is the accent's tint, not the system highlight", async () => {
        const tab = await browser.newPage();
        await tab.setContent(page(pageCss, `<p id="text">Selected text</p>`));
        const selection = await tab.$eval("#text", (node) => getComputedStyle(node, "::selection").backgroundColor);
        // color-mix of iris: the iris channels at some alpha, in whichever notation the engine uses.
        expect(selection).toMatch(/196|0\.76/);
        await tab.close();
      });

      test("the agent pane's pressed Plan toggle uses the accent, not the theme's blue", async () => {
        const tab = await browser.newPage();
        await tab.setContent(
          page(
            paneCss,
            `<div class="acpmux-shell"><button class="acpmux-plan" aria-pressed="true" id="plan">Plan</button></div>`,
          ),
        );
        const plan = await tab.$eval("#plan", (node) => {
          const style = getComputedStyle(node);
          return { color: style.color, fill: style.backgroundColor, edge: style.boxShadow };
        });
        expect(plan.color).toBe(IRIS);
        // On is accent ink alone, with no pill at rest (Leo 2026-10-19: the Claude app's chips).
        expect(plan.fill).toBe("rgba(0, 0, 0, 0)");
        expect(plan.edge).toBe("none");
        await tab.close();
      });

      // Send follows the theme in every composer and state (Leo 2026-10-19: the bright blue disc
      // was wrong): its disc is the theme's ink, never a blue the theme does not have.
      test("Send is the theme's ink in every composer and state, never a system blue", async () => {
        const tab = await browser.newPage();
        const row = (cls: string) =>
          `<button class="acpmux-send acpmux-send-ready ${cls}" data-s="ready">↑</button>` +
          `<button class="acpmux-send ${cls}" data-s="off" disabled>↑</button>` +
          `<button class="acpmux-send acpmux-cancel ${cls}" data-s="stop">■</button>`;
        await tab.setContent(
          page(
            sendCss,
            `<div class="acpmux-shell"><div class="acpmux-composer"><div class="acpmux-composer-box"><div class="acpmux-composer-bar" id="chat">${row("")}</div></div></div>` +
              `<div class="nt-composer"><div class="nt-box"><div class="nt-pickers" id="newtab">${row("nt-send")}</div></div></div></div>`,
          ),
        );
        const blue = (color: string) => {
          const [r, g, b] = [...color.matchAll(/[\d.]+/g)].map((match) => Number(match[0]));
          // color(srgb ...) channels are 0...1; rgb() channels are 0...255.
          const scale = color.startsWith("color(") ? 255 : 1;
          return (b! - Math.max(r!, g!)) * scale > 24;
        };
        const problems: string[] = [];
        for (const composer of ["chat", "newtab"])
          for (const state of ["ready", "off", "stop"]) {
            const selector = `#${composer} [data-s="${state}"]`;
            const rest = await tab.$eval(selector, (node) => getComputedStyle(node).backgroundColor);
            if (blue(rest)) problems.push(`${composer} ${state}: ${rest}`);
            await tab.hover(selector, { force: true });
            const hover = await tab.$eval(selector, (node) => getComputedStyle(node).backgroundColor);
            if (blue(hover)) problems.push(`${composer} ${state} hovered: ${hover}`);
          }
        expect(problems).toEqual([]);
        await tab.close();
      });
    });
  }
});
