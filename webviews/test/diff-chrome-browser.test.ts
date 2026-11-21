// l10n-allow-file: test assertions on the viewer's English labels, not shipped UI.
// The diff viewer's chrome in real Chromium (test/browser/diff-chrome.html), from the designer audit of the
// viewer (user 2026-11-19: "there's a lot of stuff we need to fix for diff viewer"):
// - the file header bar and the empty state ("No changes") follow Text Size (the host's
//   `--cmux-interface-scale`), as the rest of the chrome does, where they were fixed at 14 px;
// - the header bar's icon buttons (Viewed's eye, the collapse caret) round as every other button
//   (`--ds-radius-control`, the toolbar pill's buttons), where they had their own 5 px;
// - copying code rows gives the code only: no +/- signs (bars, classic or none) and no line numbers, also
//   when the drag starts on a line's first character, where the hover comment button once sat;
// - the +N -N counts (file header bar, toolbar) read over a see-through window, as code does (appearance.ts
//   `syntaxBackdrops`): fleet capture of a1eec60d, dark over a picture, the header's "+11 -4" read 1.1 to 1.7:1.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { DESKTOP_LEVELS, parseComputedColor } from "../src/backdrop";
import { contrastBetween, defaultSyntaxPalettes, SYNTAX_MIN_CONTRAST } from "../src/syntax-colors";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("diff-chrome-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  if (!(await probeEngineOrSkip("diff-chrome-browser.test.ts", "chromium", chromium))) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/diff-chrome.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A new page on the harness with `query`, once `ready` is drawn. */
  async function open(query: string, ready: string): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const context = await browser!.newContext({ viewport: { width: 900, height: 600 } });
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}/test/browser/diff-chrome.html${query}`);
    await page.locator(ready).first().waitFor();
    return page;
  }

  /** The drawn font size of `selector` at the host's Text Size `scale`. */
  function fontSizeAt(page: Page, selector: string, scale: number): Promise<string> {
    return page.evaluate(
      ([selector, scale]) => {
        document.documentElement.style.setProperty("--cmux-interface-scale", String(scale));
        return getComputedStyle(document.querySelector(selector as string)!).fontSize;
      },
      [selector, scale] as const,
    );
  }

  test("the file header bar follows Text Size", async () => {
    const page = await open("", ".file-header-name");
    try {
      expect(await fontSizeAt(page, ".file-header", 1)).toBe("14px");
      expect(await fontSizeAt(page, ".file-header", 1.25)).toBe("17.5px");
    } finally {
      await page.context().close();
    }
  });

  test("the empty state follows Text Size", async () => {
    const page = await open("?empty", 'body[data-status-only="true"] #status-text');
    try {
      expect(await page.locator("#status-text").textContent()).toBe("No changes");
      expect(await fontSizeAt(page, "#status", 1)).toBe("14px");
      expect(await fontSizeAt(page, "#status", 1.25)).toBe("17.5px");
    } finally {
      await page.context().close();
    }
  });

  test("the header bar's eye and caret round as the toolbar's buttons", async () => {
    const page = await open("", ".file-review-eye");
    try {
      const corners = (hostRadius: string | null) =>
        page.evaluate((hostRadius) => {
          const root = document.documentElement.style;
          if (hostRadius === null) root.removeProperty("--cmux-button-radius");
          else root.setProperty("--cmux-button-radius", hostRadius);
          const corner = (selector: string) => getComputedStyle(document.querySelector(selector)!).borderTopLeftRadius;
          return {
            button: corner(".diff-pill-button"),
            eye: corner(".file-review-eye"),
            caret: corner(".file-header-caret"),
          };
        }, hostRadius);
      const standalone = await corners(null);
      expect(standalone.eye).toBe(standalone.button);
      expect(standalone.caret).toBe(standalone.button);
      // The host's button corner (Metrics.buttonCornerRadius) reaches them too.
      expect(await corners("6px")).toEqual({ button: "6px", eye: "6px", caret: "6px" });
    } finally {
      await page.context().close();
    }
  });

  test("the +N -N counts read over a see-through window, and keep their look in an opaque one", async () => {
    const page = await open("", ".file-header-additions");
    try {
      await page.emulateMedia({ colorScheme: "dark" });
      // What the host sends (WebTheme.swift): its variables on the root, then `cmux-theme`. The default dark
      // terminal theme, and the window tint the capture's window laid over its picture.
      const tint = "rgba(0, 0, 0, 0.573)";
      const counts = (seeThrough: boolean) =>
        page.evaluate(
          ([seeThrough, tint, palette]) => {
            const variables: Record<string, string> = {
              "--cmux-surface-background": seeThrough ? "rgba(0, 0, 0, 0)" : "rgba(0, 0, 0, 1)",
              "--cmux-window-tint": tint as string,
            };
            const terminal = { type: "dark", background: "#000000", foreground: "#ffffff", palette };
            const payload = { variables, colorScheme: "dark", scrollers: "overlay", terminal };
            const root = document.documentElement;
            for (const [name, value] of Object.entries(variables)) root.style.setProperty(name, value);
            root.style.colorScheme = "dark";
            (window as unknown as { cmuxTheme: { current: unknown } }).cmuxTheme = { current: payload };
            window.dispatchEvent(new CustomEvent("cmux-theme", { detail: payload }));
            // The header bar always draws its counts; the toolbar's source pill only for a page with a source.
            const color = (selector: string) => {
              const element = document.querySelector(selector);
              return element ? getComputedStyle(element).color : null;
            };
            const drawn = {
              "header +": color(".file-header-additions"),
              "header -": color(".file-header-deletions"),
              "toolbar +": color(".source-pill-stats:not(.invisible) .source-pill-additions"),
              "toolbar -": color(".source-pill-stats:not(.invisible) .source-pill-deletions"),
            };
            return Object.fromEntries(Object.entries(drawn).filter(([, value]) => value !== null)) as Record<
              string,
              string
            >;
          },
          [seeThrough, tint, defaultSyntaxPalettes.dark] as const,
        );
      const hex = (css: string) => {
        const color = parseComputedColor(css);
        if (!color) throw new Error(`unparsed color ${css}`);
        return `#${[color.r, color.g, color.b].map((v) => Math.round(v).toString(16).padStart(2, "0")).join("")}`;
      };
      const opaque = await counts(false);
      expect(Object.keys(opaque)).toEqual(expect.arrayContaining(["header +", "header -"]));
      const seeThrough = await counts(true);
      // The window's tint over every desktop from black to white.
      const [, , , alpha] = tint.match(/[\d.]+/g)!.map(Number);
      const backdrops = DESKTOP_LEVELS.map((level) => {
        const gray = Math.round(level * 255 * (1 - alpha!))
          .toString(16)
          .padStart(2, "0");
        return `#${gray}${gray}${gray}`;
      });
      const weak = Object.entries(seeThrough).flatMap(([name, css]) =>
        backdrops
          .map((backdrop) => {
            // Held to 3:1, or to two thirds of what white text gets where a faint tint leaves it under that.
            const floor = Math.min(SYNTAX_MIN_CONTRAST, ((contrastBetween("#ffffff", backdrop) ?? 0) * 2) / 3);
            return { name, color: hex(css), backdrop, ratio: contrastBetween(hex(css), backdrop) ?? 0, floor };
          })
          .filter(({ ratio, floor }) => ratio < floor - 0.01)
          .map(({ name, color, backdrop, ratio }) => `${name} ${color} on ${backdrop}: ${ratio.toFixed(2)}:1`),
      );
      expect(weak).toEqual([]);
      // Back to an opaque window: the counts are as before, the theme's colors softened toward the page.
      expect(await counts(false)).toEqual(opaque);
    } finally {
      await page.context().close();
    }
  });

  for (const indicators of ["bars", "classic", "none"]) {
    test(`copying code rows (${indicators} signs) gives the code only`, async () => {
      const page = await open(`?indicators=${indicators}`, "#viewer diffs-container");
      try {
        await page.waitForFunction(
          () =>
            (document.querySelector("#viewer diffs-container")?.shadowRoot?.querySelectorAll("[data-line]").length ??
              0) >= 4,
        );
        const rows = await page.evaluate(() =>
          Array.from(
            document.querySelector("#viewer diffs-container")!.shadowRoot!.querySelectorAll("[data-line]"),
            (row) => {
              const rect = row.getBoundingClientRect();
              return { left: rect.left, right: rect.right, y: rect.top + rect.height / 2, text: row.textContent ?? "" };
            },
          ),
        );
        expect(rows.map((row) => row.text.trim())).toEqual(["#!/bin/sh", "retries=3", "retries=5", "done"]);
        // Drag from the first character of the first row to the end of the last, as a person selects
        // code (a drag that starts in a row's left padding selected nothing in headless Chromium). The rows
        // are in the diff's shadow root: Chromium reports their selection on the root
        // (`ShadowRoot.getSelection`) and sometimes only on the document, so the test reads both.
        const start = await page.evaluate(() => {
          const row = document.querySelector("#viewer diffs-container")!.shadowRoot!.querySelector("[data-line]")!;
          const text = document.createTreeWalker(row, NodeFilter.SHOW_TEXT).nextNode()!;
          const range = document.createRange();
          range.setStart(text, 0);
          range.setEnd(text, 1);
          const rect = range.getBoundingClientRect();
          return { x: rect.left + 1, y: rect.top + rect.height / 2 };
        });
        const last = rows[rows.length - 1]!;
        await page.mouse.move(start.x, start.y);
        await page.mouse.down();
        await page.mouse.move(last.right - 2, last.y, { steps: 10 });
        await page.mouse.up();
        const lines = (text: string) =>
          text
            .split("\n")
            .map((line) => line.trimEnd())
            .filter((line) => line !== "");
        // What the selection holds, and what the copy key (a real key press, as a person copies) puts on the
        // clipboard; both are the code, without signs or line numbers.
        const selected = await page.evaluate(() => {
          const root = document.querySelector("#viewer diffs-container")!.shadowRoot as ShadowRoot & {
            getSelection?: () => Selection | null;
          };
          return root.getSelection?.()?.toString() || document.getSelection()?.toString() || "";
        });
        // The browser's clipboard outlives a context: clear it, so a stale copy cannot pass.
        await page.evaluate(() => navigator.clipboard.writeText(""));
        await page.keyboard.press("ControlOrMeta+KeyC");
        const copied = await page.evaluate(() => navigator.clipboard.readText());
        expect({ selected: lines(selected), copied: lines(copied) }).toEqual({
          selected: ["#!/bin/sh", "retries=3", "retries=5", "done"],
          copied: ["#!/bin/sh", "retries=3", "retries=5", "done"],
        });
      } finally {
        await page.context().close();
      }
    });
  }
});
