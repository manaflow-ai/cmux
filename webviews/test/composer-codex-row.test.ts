// Both composer looks lay the buttons out as Claude's (Leo 2026-11-01: "the placement of the buttons
// are just really bad compared to our claude code version", then "we already have a good version";
// leo-workspace design/composer.md, Codex's look): + left of the prompt and the mic (and the send
// slot) right of it inside the box, the mode, model and context ring in the quiet row under it.
// Codex's look draws every control where Claude's does, in the chat and on New Tab. Replaced: Codex's
// own row in the box under the prompt (cmux #28901). Captures are gallery fixtures, never private
// reference images.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-codex-row.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-codex-row", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const out = path.resolve(process.env.COMPOSER_CAPTURE_DIR ?? path.join(webviews, "artifacts/codex-composer"));
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "claude-chat" } });
    mkdirSync(out, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );

  /** Every control's box relative to the composer box, and whether it sits inside the box. */
  const measure = (page: Page, composerSelector: string, boxSelector: string) =>
    page.evaluate(
      ({ composerSelector, boxSelector }) => {
        const composer = document.querySelector(composerSelector)!;
        const box = composer.querySelector(boxSelector)!;
        const b = box.getBoundingClientRect();
        const controls = Object.fromEntries(
          [
            ".acpmux-composer-plus .acpmux-picker-button",
            ".acpmux-access-trigger",
            ".acpmux-model .acpmux-picker-button",
            ".acpmux-context-ring",
            ".acpmux-mic",
            ".acpmux-send",
          ].flatMap((selector) => {
            const el = composer.querySelector(selector);
            if (!el) return [];
            const r = el.getBoundingClientRect();
            if (r.width === 0) return [];
            return [
              [
                selector,
                {
                  inside: box.contains(el),
                  left: r.left - b.left,
                  right: r.right - b.left,
                  top: r.top - b.top,
                  bottom: r.bottom - b.top,
                  width: r.width,
                  height: r.height,
                },
              ],
            ];
          }),
        );
        // A press at each control's centre reaches that control, not the dots' host over the row.
        const unreachable = Object.keys(controls).filter((selector) => {
          const el = composer.querySelector(selector)!;
          const r = el.getBoundingClientRect();
          const hit = document.elementFromPoint((r.left + r.right) / 2, (r.top + r.bottom) / 2);
          return !hit || !el.contains(hit);
        });
        return {
          box: { width: b.width, height: b.height },
          controls,
          unreachable,
          foot: !!composer.querySelector(".acpmux-composer-foot"),
          grid: box.hasAttribute("data-composer-grid") || !!box.querySelector(".nt-input[data-split]"),
        };
      },
      { composerSelector, boxSelector },
    );

  for (const theme of ["light", "dark"])
    for (const width of [720, 420, 280])
      test(`${theme} ${width}: Codex's look draws every control where Claude's does`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          const shot = async (look: "claude" | "codex") => {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", {
                variant: `${look}-chat`,
                theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
              })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.evaluate(() => document.fonts.ready);
            await page.mouse.move(0, 0);
            await settle(page);
            const geometry = await measure(page, ".acpmux-composer", ".acpmux-composer-box");
            const stem = `${look}-${theme}-${width}`;
            await page
              .locator(".acpmux-composer")
              .screenshot({ path: path.join(out, `${stem}.png`), animations: "disabled", caret: "hide" });
            writeFileSync(path.join(out, `${stem}.json`), JSON.stringify(geometry, null, 2));
            console.log(`COMPOSER_GEOMETRY ${stem} ${JSON.stringify(geometry)}`);
            return geometry;
          };
          const claude = await shot("claude");
          const codex = await shot("codex");
          for (const geometry of [claude, codex]) {
            expect(geometry.grid).toBe(true);
            expect(geometry.foot).toBe(true);
            expect(geometry.unreachable).toEqual([]);
            const { controls } = geometry;
            expect(Object.keys(controls)).toContain(".acpmux-model .acpmux-picker-button");
            expect(Object.keys(controls)).toContain(".acpmux-access-trigger");
            // + and the mic in the box, on its 8 px inset; the mode, model and ring under it.
            const plus = controls[".acpmux-composer-plus .acpmux-picker-button"]!;
            expect(plus.inside).toBe(true);
            expect(plus.width).toBe(28);
            expect(plus.height).toBe(28);
            expect(Math.abs(plus.left - 8)).toBeLessThanOrEqual(0.5);
            const mic = controls[".acpmux-mic"];
            if (mic) {
              expect(mic.inside).toBe(true);
              expect(Math.abs(geometry.box.width - mic.right - 8)).toBeLessThanOrEqual(0.5);
              expect(Math.abs(mic.top - plus.top)).toBeLessThanOrEqual(0.5);
            }
            for (const selector of [
              ".acpmux-access-trigger",
              ".acpmux-model .acpmux-picker-button",
              ".acpmux-context-ring",
            ])
              if (controls[selector]) {
                expect(controls[selector]!.inside).toBe(false);
                expect(controls[selector]!.top).toBeGreaterThanOrEqual(geometry.box.height);
              }
          }
          // The same box and the same place for every control in both looks.
          expect(Math.abs(codex.box.height - claude.box.height)).toBeLessThanOrEqual(0.5);
          expect(Object.keys(codex.controls).sort()).toEqual(Object.keys(claude.controls).sort());
          for (const [selector, c] of Object.entries(claude.controls)) {
            const x = codex.controls[selector]!;
            for (const edge of ["left", "right", "top", "bottom"] as const)
              expect(Math.abs(x[edge] - c[edge]), `${selector} ${edge}`).toBeLessThanOrEqual(0.5);
          }
        } finally {
          await page.close();
        }
      });

  // New Tab in Codex's look splits as Claude's: + before the field, the mic and Send after it, the
  // mode and model in the quiet row under the box; a narrow pane steps the labels down there.
  for (const width of [1200, 720, 480, 420, 280])
    test(`codex New Tab ${width}: Claude's split, the chips in the quiet row`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        const open = async (look: "claude" | "codex") => {
          await page.addInitScript((value) => localStorage.setItem("cmux.composer.look", value), look);
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", { variant: "minimal-default", width })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.waitForSelector(".nt-composer .acpmux-composer-foot .acpmux-model");
          await page.evaluate(() => document.fonts.ready);
          await settle(page);
          return {
            look: await page.evaluate(() => document.querySelector(".nt-composer")!.getAttribute("data-composer-look")),
            plusSplit: await page.evaluate(() => !!document.querySelector(".nt-composer .nt-box .nt-split-plus")),
            ...(await measure(page, ".nt-composer", ".nt-box")),
          };
        };
        const codex = await open("codex");
        await page
          .locator(".nt-composer")
          .screenshot({ path: path.join(out, `codex-newtab-${width}.png`), animations: "disabled", caret: "hide" });
        expect(codex.look).toBe("codex");
        expect(codex.plusSplit).toBe(true);
        expect(codex.foot).toBe(true);
        for (const selector of [".acpmux-access-trigger", ".acpmux-model .acpmux-picker-button"])
          expect(codex.controls[selector]?.inside).toBe(false);
        for (const selector of [".acpmux-composer-plus .acpmux-picker-button", ".acpmux-mic", ".acpmux-send"])
          if (codex.controls[selector]) expect(codex.controls[selector]!.inside).toBe(true);
        const claude = await open("claude");
        expect(claude.look).toBeNull();
        for (const [selector, c] of Object.entries(claude.controls)) {
          const x = codex.controls[selector];
          expect(x, selector).toBeDefined();
          // The tray over Codex's box moves the whole composer down, never a control within it.
          for (const edge of ["left", "right", "top", "bottom"] as const)
            expect(Math.abs(x![edge] - c[edge]), `${selector} ${edge}`).toBeLessThanOrEqual(0.5);
        }
      } finally {
        await page.close();
      }
    });
});
