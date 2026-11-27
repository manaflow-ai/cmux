// cmux-web-test-timeout: 180
// These are mounted New Tab gallery interactions: a rendered screenshot alone can miss a thrown
// play, so keep the final play receipt and the user-visible state together.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { RowGlyph, SuggestionGlyph } from "../src/agent-session/acpmux/newtab/RowGlyph";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-gallery-reached.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const entries = ["agent-pane.new-tab", "agent-pane.chat-cards-loading"];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entries, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [entry, variant] of [
    ["agent-pane.new-tab", "empty"],
    ["agent-pane.new-tab", "attachment-menu"],
    ["agent-pane.new-tab", "style-switch"],
    ["agent-pane.new-tab", "suggestions-create"],
    // A dark one-colour favicon in the label colour; with a file attached, only Ask rows (both plays wait
    // for that state and throw at the cap).
    ["agent-pane.new-tab", "suggestions-dark-favicon"],
    ["agent-pane.new-tab", "suggestions-attached"],
  ] as const) {
    test(`${entry}#${variant} reaches its mounted interaction`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
          timeout: 90_000,
        });
        const receipt = await page.evaluate(() => ({
          ready: document.documentElement.dataset.galleryReady,
          report: (
            window as unknown as {
              cmuxGalleryPlayReport?: {
                status?: string;
                error?: string;
                steps?: Array<{
                  step?: string;
                  layoutShift?: number;
                  problems?: string[];
                  popupProblems?: string[];
                  anchorMoves?: unknown[];
                }>;
              };
            }
          ).cmuxGalleryPlayReport,
          attach: document.querySelector('.acpmux-newtab-plus [data-value="add.files"]') !== null,
          multi: document.querySelector<HTMLInputElement>(".nt-composer .acpmux-attach-input")?.multiple ?? false,
          // Minimal draws no chat list, empty or loading.
          chatList: document.querySelector(".nt-cards, .nt-chats-empty") !== null,
          savedMinimal: (
            (window as unknown as { cmuxGalleryLog?: Array<{ method: string; params?: { template?: string } }> })
              .cmuxGalleryLog ?? []
          ).some((call) => call.method === "newTab.setTemplate" && call.params?.template === "minimal"),
        }));
        expect(receipt.ready).toBe("1");
        expect(receipt.report?.error).toBeUndefined();
        const steps = receipt.report?.steps ?? [];
        // State fixtures wait for their content; only interaction plays record input steps.
        if (variant !== "empty" && variant !== "suggestions-create") expect(steps.length).toBeGreaterThan(0);
        for (const step of steps) {
          expect(step.popupProblems ?? []).toEqual([]);
          expect(step.anchorMoves ?? []).toEqual([]);
        }
        // Graded as every play test is (support/galleryPlay.ts): a thrown play, a moved anchor and a
        // unexpected layout shift fail it; the runner's frame timing does not (cx-mfkky).
        if (variant !== "empty") expect(playFailures(JSON.stringify(receipt.report))).toEqual([]);
        if (variant === "attachment-menu") {
          expect(receipt.attach).toBe(true);
          expect(receipt.multi).toBe(true);
        }
        if (variant === "empty") expect(receipt.chatList).toBe(false);
        if (variant === "style-switch") expect(receipt.savedMinimal).toBe(true);
      } finally {
        await page.close();
      }
    });
  }

  test("Ask logos scale with their glyph box and stay centered beside outline icons", async () => {
    const page = await browser!.newPage();
    try {
      const css = readFileSync(path.join(webviews, "src/agent-session/acpmux/newtab/screen.css"), "utf8");
      const asks = ["claude", "codex"].map((harness) =>
        renderToStaticMarkup(
          createElement(SuggestionGlyph, { row: { type: "ask", text: "hello", harness, agent: harness } }),
        ),
      );
      const outline = renderToStaticMarkup(createElement(RowGlyph, { kind: "search" }));
      await page.setContent(`<style>${css}</style><div class="nt-popover">${asks.join("")}${outline}</div>`);
      for (const size of [16, 24, 32]) {
        await page.locator(".nt-popover").evaluate((element, size) => {
          (element as HTMLElement).style.setProperty("--acpmux-composer-glyph", `${size}px`);
        }, size);
        const glyphs = await page.locator(".nt-row-glyph").evaluateAll((elements) =>
          elements.map((element) => {
            const svg = element.querySelector("svg")!;
            const box = element.getBoundingClientRect();
            const icon = svg.getBoundingClientRect();
            const stroke = Math.max(
              0,
              ...[...svg.querySelectorAll('[stroke]:not([stroke="none"])')].map((path) =>
                Number.parseFloat(getComputedStyle(path).strokeWidth),
              ),
            );
            return {
              box: box.height,
              width: icon.width,
              height: icon.height,
              ink: ((svg.getBBox().height + stroke) / svg.viewBox.baseVal.height) * icon.height,
              centerX: (icon.left + icon.right - box.left - box.right) / 2,
              centerY: (icon.top + icon.bottom - box.top - box.bottom) / 2,
            };
          }),
        );
        expect(glyphs).toHaveLength(3);
        const outlineInk = glyphs[2]!.ink;
        for (const mark of glyphs.slice(0, 2)) {
          expect(mark.box).toBeCloseTo(size, 1);
          expect(mark.height / mark.box).toBeGreaterThan(0.65);
          expect(mark.height / mark.box).toBeLessThan(14 / 16);
          expect(mark.width).toBeCloseTo(mark.height, 1);
          expect(mark.centerX).toBeCloseTo(0, 1);
          expect(mark.centerY).toBeCloseTo(0, 1);
          expect(mark.ink / outlineInk).toBeGreaterThan(0.75);
          expect(mark.ink / outlineInk).toBeLessThan(1.25);
        }
      }
    } finally {
      await page.close();
    }
  });

  test("a favicon draws centered in the icon's box at a logo's size, in the suggestions and the lists", async () => {
    const page = await browser!.newPage();
    try {
      const css = readFileSync(path.join(webviews, "src/agent-session/acpmux/newtab/screen.css"), "utf8");
      const icon = `data:image/svg+xml,${encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="red"/></svg>',
      )}`;
      const pair = [
        renderToStaticMarkup(createElement(RowGlyph, { kind: "tab", icon })),
        renderToStaticMarkup(createElement(RowGlyph, { kind: "browser" })),
      ].join("");
      await page.setContent(
        `<style>${css}</style><div class="nt-popover">${pair}</div><nav class="nt-open-tabs">${pair}</nav>`,
      );
      await page
        .locator("img.nt-row-favicon")
        .first()
        .evaluate((img) => (img as HTMLImageElement).decode());
      for (const size of [16, 24, 32]) {
        await page.evaluate((size) => {
          for (const list of document.querySelectorAll<HTMLElement>(".nt-popover, .nt-open-tabs"))
            list.style.setProperty("--acpmux-composer-glyph", `${size}px`);
        }, size);
        for (const [list, ink] of [
          [".nt-popover", (size * 14) / 16],
          [".nt-open-tabs", size],
        ] as const) {
          const glyphs = await page.locator(`${list} .nt-row-glyph`).evaluateAll((elements) =>
            elements.map((element) => {
              const box = element.getBoundingClientRect();
              const drawn = element.firstElementChild!.getBoundingClientRect();
              return {
                box: box.width,
                width: drawn.width,
                height: drawn.height,
                centerX: (drawn.left + drawn.right - box.left - box.right) / 2,
                centerY: (drawn.top + drawn.bottom - box.top - box.bottom) / 2,
              };
            }),
          );
          expect(glyphs).toHaveLength(2);
          const [favicon, outline] = glyphs as [(typeof glyphs)[0], (typeof glyphs)[0]];
          // The outline icon fills the ink size; a favicon, a filled logo, 12 of its 14 as an agent mark does.
          expect(favicon.box).toBeCloseTo(outline.box, 2);
          expect(outline.width).toBeCloseTo(ink, 1);
          expect(favicon.width).toBeCloseTo((ink * 12) / 14, 1);
          expect(favicon.height).toBeCloseTo((ink * 12) / 14, 1);
          expect(favicon.centerX).toBeCloseTo(0, 1);
          expect(favicon.centerY).toBeCloseTo(0, 1);
        }
      }
    } finally {
      await page.close();
    }
  });

  for (const variant of ["cards", "list"] as const) {
    test(`recent chat ${variant} placeholders preserve row heights and metadata positions`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 620, height: 420 } });
      try {
        const geometry = async (state: "loaded" | "pending") => {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-cards-loading", { variant: `${state}-${variant}` })}`,
          );
          await page.waitForSelector(".nt-card");
          return page.locator(".nt-card").evaluateAll((rows) =>
            rows.map((row) => {
              const rect = (selector: string) => row.querySelector(selector)!.getBoundingClientRect();
              return {
                height: row.getBoundingClientRect().height,
                titleLeft: rect(".nt-card-title").left,
                metaLeft: rect(".nt-card-meta").left,
                ageLeft: rect(".nt-card-age").left,
                ageRight: rect(".nt-card-age").right,
              };
            }),
          );
        };
        const loaded = await geometry("loaded");
        const pending = await geometry("pending");
        expect(loaded).toHaveLength(3);
        expect(pending).toHaveLength(3);
        for (let index = 0; index < loaded.length; index++) {
          expect(pending[index]!.height).toBeCloseTo(loaded[index]!.height, 0);
          expect(pending[index]!.titleLeft).toBeCloseTo(loaded[index]!.titleLeft, 0);
          expect(pending[index]!.metaLeft).toBeCloseTo(loaded[index]!.metaLeft, 0);
          expect(pending[index]!.ageLeft).toBeCloseTo(loaded[index]!.ageLeft, 0);
          // Only list ages occupy a fixed column; card ages size to their text.
          if (variant === "list") expect(pending[index]!.ageRight).toBeCloseTo(loaded[index]!.ageRight, 0);
        }
      } finally {
        await page.close();
      }
    });
  }
});
