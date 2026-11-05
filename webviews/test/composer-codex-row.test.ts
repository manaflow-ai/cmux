// Leo 2026-11-04: "we still don't have the proper spacing". Codex's look follows the ChatGPT
// composer reference: a full-width prompt above one lower row with + left, mic/Send right, and
// every existing mode/model/context control between them. Claude and New Tab keep their compact
// split. Captures contain gallery fixtures, never private reference images.
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
      root: webviews,
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
        const prompt = box.querySelector(".ProseMirror > p")?.getBoundingClientRect();
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
          prompt: prompt
            ? { top: prompt.top - b.top, bottom: prompt.bottom - b.top, left: prompt.left - b.left }
            : null,
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
      test(`${theme} ${width}: Codex's prompt stands above one reachable lower controls row`, async () => {
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
          for (const [look, geometry] of [
            ["claude", claude],
            ["codex", codex],
          ] as const) {
            expect(geometry.grid).toBe(true);
            expect(geometry.foot).toBe(true);
            expect(geometry.unreachable).toEqual([]);
            const { controls } = geometry;
            expect(Object.keys(controls)).toContain(".acpmux-model .acpmux-picker-button");
            expect(Object.keys(controls)).toContain(".acpmux-access-trigger");
            // + and the mic keep equal side insets, and the same row and control size.
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
                const control = controls[selector]!;
                if (look === "claude") {
                  expect(control.inside).toBe(false);
                  expect(control.top).toBeGreaterThanOrEqual(geometry.box.height);
                } else {
                  expect(control.inside).toBe(true);
                  expect(
                    Math.abs((control.top + control.bottom) / 2 - (plus.top + plus.bottom) / 2),
                  ).toBeLessThanOrEqual(0.5);
                  expect(control.bottom).toBeLessThanOrEqual(geometry.box.height);
                  expect(control.left).toBeGreaterThanOrEqual(0);
                  expect(control.right).toBeLessThanOrEqual(geometry.box.width);
                }
              }
          }
          // The placeholder owns its line, above +, with the reference's clear separation. The
          // lower controls have equal 8px edge insets, while the text starts 16px into the box.
          const plus = codex.controls[".acpmux-composer-plus .acpmux-picker-button"]!;
          expect(codex.prompt).not.toBeNull();
          expect(Math.abs(codex.prompt!.top - 16)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(codex.prompt!.left - 16)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(plus.top - codex.prompt!.bottom - 24)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(codex.box.height - plus.bottom - 8)).toBeLessThanOrEqual(0.5);
          console.log(`COMPOSER_PROMPT_CONTROL_GAP ${theme}-${width} ${plus.top - codex.prompt!.bottom}`);
          // The switch keeps every control and both horizontal edge insets.
          expect(codex.box.height).toBeGreaterThan(claude.box.height + 20);
          expect(Object.keys(codex.controls).sort()).toEqual(Object.keys(claude.controls).sort());
          for (const selector of [".acpmux-composer-plus .acpmux-picker-button", ".acpmux-mic", ".acpmux-send"]) {
            const c = claude.controls[selector];
            const x = codex.controls[selector];
            if (!c || !x) continue;
            for (const edge of ["left", "right"] as const)
              expect(Math.abs(x[edge] - c[edge]), `${selector} ${edge}`).toBeLessThanOrEqual(0.5);
          }
        } finally {
          await page.close();
        }
      });

  // The Codex disc fills arrive from the look's follow-up style, but both the current Stop slot and
  // the existing gallery disc use the same Send focus contract. Keep keyboard focus visible when
  // the pointer is elsewhere; the shared focus pill is transparent for this control by design.
  test("Codex Send and Stop keep a visible keyboard focus wash", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      const focusFill = async (variant: string) => {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.mouse.move(0, 0);
        await settle(page);
        const send = page.locator(".acpmux-composer-box .acpmux-send");
        const rest = await send.evaluate((el) => getComputedStyle(el).backgroundColor);
        await page.keyboard.press("Tab");
        await send.focus();
        await send.evaluate(async (el) => {
          await Promise.all(
            el.getAnimations({ subtree: true }).map((animation) => animation.finished.catch(() => undefined)),
          );
        });
        await settle(page);
        return page.evaluate((rest) => {
          const el = document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-send")!;
          return {
            focusVisible: el.matches(":focus-visible"),
            fill: getComputedStyle(el).backgroundColor,
            rest,
          };
        }, rest);
      };
      const stop = await focusFill("send-one-slot-codex-running");
      expect(stop.focusVisible).toBe(true);
      expect(stop.rest).toBe("rgba(0, 0, 0, 0)");
      expect(stop.fill).not.toBe(stop.rest);
      const ready = await focusFill("send-one-slot-codex-typed");
      expect(ready.focusVisible).toBe(true);
      // The shipped ready Send remains a transparent glyph; the focus wash must not turn it into
      // the gallery-only filled-disc alternate.
      expect(ready.rest).toBe("rgba(0, 0, 0, 0)");
      expect(ready.fill).toBe(stop.fill);
      expect(ready.fill).not.toBe(ready.rest);
      const send = await focusFill("send-alt-filled-disc");
      expect(send.focusVisible).toBe(true);
      expect(send.rest).not.toBe("rgba(0, 0, 0, 0)");
      expect(send.fill).not.toBe(send.rest);
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
