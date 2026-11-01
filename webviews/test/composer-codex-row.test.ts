// Codex keeps its mode/model/context controls beside + and the send controls inside the box, with
// the look dots in that row's empty middle.
// Claude keeps the quiet footer. Captures are gallery fixtures, never private reference images.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
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

  for (const look of ["claude", "codex"])
    for (const theme of ["light", "dark"])
      for (const width of [720, 420, 280])
        test(`${look} ${theme} ${width}: controls belong to their look's row`, async () => {
          const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
          try {
            const port = (vite.httpServer!.address() as { port: number }).port;
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", {
                variant: `${look}-chat`,
                theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
              })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.evaluate(() => document.fonts.ready);
            await page.mouse.move(0, 0);
            await page.evaluate(
              () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
            );
            const geometry = await page.evaluate(() => {
              const composer = document.querySelector(".acpmux-composer")!;
              const box = composer.querySelector(".acpmux-composer-box")!;
              const bounds = (el: Element) => {
                const r = el.getBoundingClientRect();
                return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, cy: (r.top + r.bottom) / 2 };
              };
              const controls = [
                ".acpmux-composer-plus .acpmux-picker-button",
                ".acpmux-access-trigger",
                ".acpmux-model .acpmux-picker-button",
                ".acpmux-context-ring",
                ".acpmux-mic",
                ".acpmux-send",
              ].flatMap((selector) => {
                const el = composer.querySelector(selector);
                return el ? [{ selector, inside: box.contains(el), ...bounds(el) }] : [];
              });
              const bar = box.querySelector(".acpmux-composer-bar")!;
              // A pane too narrow for a clear middle hides the dots (composerLook.css): zero size.
              const dotsEl = composer.querySelector(".acpmux-composer-under .acpmux-look-dots");
              const dots = dotsEl && dotsEl.getBoundingClientRect().width > 0 ? dotsEl : null;
              // A press at each control's centre reaches that control, not the dots' host over the row.
              const unreachable = [
                ".acpmux-composer-plus .acpmux-picker-button",
                ".acpmux-access-trigger",
                ".acpmux-model .acpmux-picker-button",
                ".acpmux-mic",
                ".acpmux-send",
              ].filter((selector) => {
                const el = composer.querySelector(selector);
                if (!el) return false;
                const r = el.getBoundingClientRect();
                const hit = document.elementFromPoint((r.left + r.right) / 2, (r.top + r.bottom) / 2);
                return !hit || !el.contains(hit);
              });
              // The floating dock gives each composer part the pointer (bottomStack.css); the host still passes it.
              const probe = document.createElement("div");
              probe.className = "acpmux-main";
              probe.dataset.dock = "float";
              probe.innerHTML =
                '<div class="acpmux-dock"><form class="acpmux-composer" data-composer-look="codex"><div class="acpmux-composer-under"></div></form></div>';
              document.body.append(probe);
              const floatHost = getComputedStyle(probe.querySelector(".acpmux-composer-under")!).pointerEvents;
              probe.remove();
              return {
                box: bounds(box),
                composer: bounds(composer),
                controls,
                bar: bounds(bar),
                dots: dots ? bounds(dots) : null,
                unreachable,
                floatHost,
                emptyAttachments: !!box.querySelector(".acpmux-attachments:empty"),
              };
            });
            const stem = `${look}-${theme}-${width}`;
            await page
              .locator(".acpmux-composer")
              .screenshot({ path: path.join(out, `${stem}.png`), animations: "disabled", caret: "hide" });
            writeFileSync(path.join(out, `${stem}.json`), JSON.stringify(geometry, null, 2));
            console.log(`COMPOSER_GEOMETRY ${stem} ${JSON.stringify(geometry)}`);
            expect(geometry.emptyAttachments).toBe(false);
            expect(geometry.controls.some((c) => c.selector.includes("acpmux-model"))).toBe(true);
            expect(geometry.controls.some((c) => c.selector.includes("acpmux-access"))).toBe(true);
            if (look === "codex") {
              expect(geometry.unreachable).toEqual([]);
              expect(geometry.floatHost).toBe("none");
              expect(geometry.controls.every((c) => c.inside)).toBe(true);
              const axis = geometry.controls[0]!.cy;
              for (const control of geometry.controls) expect(Math.abs(control.cy - axis)).toBeLessThanOrEqual(0.5);
              expect(geometry.box.bottom - geometry.bar.bottom).toBeLessThanOrEqual(0.5);
              // The box stands a 12 px floor over the composer's bottom, never on it (Leo 2026-11-01:
              // "so there's not so much uncomfortable tangent line at the bottom"), and the row is 44 px
              // with + as far off the box's left as off its bottom.
              expect(Math.abs(geometry.composer.bottom - geometry.box.bottom - 12)).toBeLessThanOrEqual(0.5);
              expect(Math.abs(geometry.bar.bottom - geometry.bar.top - 44)).toBeLessThanOrEqual(0.5);
              // Every control fits the box, none over another, at a split pane's width too (review of
              // #28901: the plain footer's infinite fit width kept the full labels at 280 px).
              const row = [...geometry.controls].sort((a, b) => a.left - b.left);
              for (const control of row) {
                expect(control.left).toBeGreaterThanOrEqual(geometry.box.left - 0.5);
                expect(control.right).toBeLessThanOrEqual(geometry.box.right + 0.5);
              }
              for (let i = 1; i < row.length; i++) expect(row[i]!.left).toBeGreaterThanOrEqual(row[i - 1]!.right - 0.5);
              // The look dots sit in the row's empty middle (Leo 2026-10-30: "you notice how the middle
              // of the normal codex compser has all that blank space? we can just have the dots there.").
              if (width >= 720) expect(geometry.dots).not.toBeNull();
              if (geometry.dots) {
                expect(geometry.dots.top).toBeGreaterThanOrEqual(geometry.bar.top);
                expect(geometry.dots.bottom).toBeLessThanOrEqual(geometry.bar.bottom);
                const leftEdge = Math.max(
                  ...geometry.controls.filter((c) => /plus|access/.test(c.selector)).map((c) => c.right),
                );
                const rightEdge = Math.min(
                  ...geometry.controls.filter((c) => !/plus|access/.test(c.selector)).map((c) => c.left),
                );
                expect(geometry.dots.left).toBeGreaterThanOrEqual(leftEdge);
                expect(geometry.dots.right).toBeLessThanOrEqual(rightEdge);
              }
            } else {
              for (const control of geometry.controls.filter((c) => /access|model|context/.test(c.selector)))
                expect(control.inside).toBe(false);
            }
          } finally {
            await page.close();
          }
        });

  // New Tab's Codex look keeps its chips in the box's row too; a narrow pane steps their labels down
  // rather than wrapping the mic and Send or clipping the model (review of #28901).
  for (const width of [1200, 720, 480, 440, 420, 400, 280])
    test(`codex New Tab ${width}: one row inside the box, nothing overlapping`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
      try {
        await page.addInitScript(() => localStorage.setItem("cmux.composer.look", "codex"));
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", { variant: "minimal-default", width })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.waitForSelector('.nt-composer[data-composer-look="codex"] .nt-box .nt-pickers .acpmux-model');
        await page.evaluate(() => document.fonts.ready);
        await page.evaluate(
          () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
        );
        const geometry = await page.evaluate(() => {
          // The model keeps a visible identity (its name, family, short name or mark) at every width.
          const model = document.querySelector(".nt-composer .nt-box .nt-pickers .acpmux-model .acpmux-picker-button")!;
          const modelShown = [...model.querySelectorAll<HTMLElement>("*")].some((el) => {
            const style = getComputedStyle(el);
            const r = el.getBoundingClientRect();
            if (style.visibility !== "visible" || r.width < 4 || r.height < 4) return false;
            const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent!.trim().length > 0);
            return own || el.classList.contains("agent-mark") || !!el.getAttribute("data-label");
          });
          const box = document.querySelector(".nt-composer .nt-box")!.getBoundingClientRect();
          const row = document.querySelector(".nt-composer .nt-box .nt-pickers")!;
          const parts = [".acpmux-access", ".acpmux-model", ".acpmux-mic", ".acpmux-send"].flatMap((selector) => {
            const el = row.querySelector(selector);
            if (!el) return [];
            const r = el.getBoundingClientRect();
            return [{ selector, left: r.left, right: r.right, cy: (r.top + r.bottom) / 2 }];
          });
          // The permission mode's label is drawn whole or not at all: never cut by the trigger's
          // clip (Leo 2026-10-31, New Tab read "s pern" for "Bypass permissions": "STUPID").
          const trigger = row.querySelector<HTMLElement>(".acpmux-access-trigger");
          const label = trigger?.querySelector<HTMLElement>(".acpmux-mode-text");
          const labelStyle = label ? getComputedStyle(label) : undefined;
          const labelShown =
            !!labelStyle &&
            labelStyle.display !== "none" &&
            labelStyle.visibility === "visible" &&
            labelStyle.position !== "absolute";
          const access = trigger
            ? {
                labelShown,
                text: label?.textContent ?? "",
                trigger: (({ left, right }) => ({ left, right }))(trigger.getBoundingClientRect()),
                label: label ? (({ left, right }) => ({ left, right }))(label.getBoundingClientRect()) : undefined,
                overflow: trigger.scrollWidth - trigger.clientWidth,
              }
            : undefined;
          return {
            modelShown,
            access,
            box: { left: box.left, right: box.right },
            parts,
            foot: !!document.querySelector(".nt-composer .acpmux-composer-foot"),
          };
        });
        await page
          .locator(".nt-composer")
          .screenshot({ path: path.join(out, `codex-newtab-${width}.png`), animations: "disabled", caret: "hide" });
        expect(geometry.foot).toBe(false);
        expect(geometry.modelShown).toBe(true);
        expect(geometry.access).toBeDefined();
        const access = geometry.access!;
        // Wide enough for the label it shows; at every width a shown label is whole.
        if (width >= 720) expect(access.labelShown).toBe(true);
        if (access.labelShown) {
          expect(access.overflow).toBeLessThanOrEqual(0);
          expect(access.text.length).toBeGreaterThan(0);
          expect(access.label!.left).toBeGreaterThanOrEqual(access.trigger.left - 0.5);
          expect(access.label!.right).toBeLessThanOrEqual(access.trigger.right + 0.5);
        }
        expect(geometry.parts.map((p) => p.selector)).toEqual([
          ".acpmux-access",
          ".acpmux-model",
          ".acpmux-mic",
          ".acpmux-send",
        ]);
        for (const part of geometry.parts) {
          expect(Math.abs(part.cy - geometry.parts[0]!.cy)).toBeLessThanOrEqual(1);
          expect(part.left).toBeGreaterThanOrEqual(geometry.box.left - 0.5);
          expect(part.right).toBeLessThanOrEqual(geometry.box.right + 0.5);
        }
        const sorted = [...geometry.parts].sort((a, b) => a.left - b.left);
        for (let i = 1; i < sorted.length; i++)
          expect(sorted[i]!.left).toBeGreaterThanOrEqual(sorted[i - 1]!.right - 0.5);
      } finally {
        await page.close();
      }
    });
});
