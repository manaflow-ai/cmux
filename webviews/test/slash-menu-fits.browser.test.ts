// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
//
// David Beyer (2026-11-20, launch review): the `/` menu on the main screen (New Tab's composer) had
// a messy font and ran over the screen's edge. The list stood above New Tab's box whatever room was
// there: in a short window it ran past the window's top (in the app the host then moved it into its
// native panel past the window, one run-together line per row). Its corners (8 px) and type (13 px
// rows, 11 px uppercase tracked tags, italic hints) were the chat's, not those of the box it stands on.
//
// The same list serves the agent chat (SlashMenu.tsx). At each window size, in light and dark, at
// the compact density and the largest interface scale, in real Chromium on the gallery stages:
// - the list is wholly inside the window, a margin off each edge;
// - it stands 6 px beside the box (above, or below when there is more room there), on its edges;
// - its corners are the box's own, so the two read as one surface;
// - it shows at least three rows;
// - its rows set every part in the field's typeface, upright and in normal case, the command and
//   what it does at one size, nothing drawn past the row's end.
// CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("slash-menu-fits.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const STAGES = [
    { name: "new-tab", entry: "agent-pane.new-tab", variant: "slash-menu-full", box: ".nt-box" },
    { name: "new-tab-cards", entry: "agent-pane.new-tab", variant: "slash-menu-cards", box: ".nt-box" },
    { name: "chat", entry: "agent-pane.composer", variant: "slash-menu-full", box: ".acpmux-composer-box" },
  ] as const;
  const WINDOWS = [
    { width: 1040, height: 760 },
    { width: 760, height: 480 },
    { width: 520, height: 400 },
  ] as const;
  const LOOKS = [
    { name: "light", params: { colorScheme: "light" } },
    { name: "dark", params: { colorScheme: "dark" } },
    { name: "compact", params: { colorScheme: "light", density: "compact" } },
    { name: "large", params: { colorScheme: "dark", interfaceScale: 1.25 } },
  ] as const;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
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
    browser = await chromium.launch({ headless: true });
    for (const stage of STAGES)
      await warmGalleryFrame(vite, stage.entry, { browser, params: { variant: stage.variant } });
  }, 300_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("the composer's / list fits its window and reads as its box's", () => {
    for (const stage of STAGES)
      for (const size of WINDOWS)
        for (const look of LOOKS)
          test(`${stage.name} ${size.width}x${size.height} ${look.name}`, async () => {
            const page = await browser!.newPage({ viewport: size });
            const errors: string[] = [];
            page.on("pageerror", (error) => errors.push(error.message));
            try {
              const port = (vite!.httpServer!.address() as { port: number }).port;
              await page.goto(
                `http://127.0.0.1:${port}${galleryFrame(stage.entry, { variant: stage.variant, reducedMotion: "true", ...look.params })}`,
              );
              await page.waitForFunction(
                () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
                undefined,
                { timeout: 90_000 },
              );
              expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
              await page.waitForSelector("#acpmux-slash-menu [role=option]");
              // The list's placement follows the box's resize observer: one frame to settle.
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              const found = await page.evaluate((boxSelector) => {
                const list = document.querySelector<HTMLElement>("#acpmux-slash-menu")!;
                const shell = list.parentElement!;
                const box = document.querySelector<HTMLElement>(boxSelector)!;
                const field = box.querySelector<HTMLElement>("[contenteditable='true']")!;
                const s = shell.getBoundingClientRect();
                const b = box.getBoundingClientRect();
                const radius = (element: Element) => {
                  const css = getComputedStyle(element);
                  return Math.max(
                    ...[
                      css.borderTopLeftRadius,
                      css.borderTopRightRadius,
                      css.borderBottomLeftRadius,
                      css.borderBottomRightRadius,
                    ].map((value) => Number.parseFloat(value) || 0),
                  );
                };
                const rows = [...list.querySelectorAll<HTMLElement>("[role=option]")];
                const shown = rows.filter((row) => {
                  const r = row.getBoundingClientRect();
                  const l = list.getBoundingClientRect();
                  return r.top >= l.top - 1 && r.bottom <= l.bottom + 1;
                });
                const spill: string[] = [];
                const faces = new Set<string>();
                const odd: string[] = [];
                const sizes: Record<string, Set<string>> = { name: new Set(), description: new Set(), hint: new Set() };
                for (const row of rows) {
                  const end = row.getBoundingClientRect().right;
                  for (const part of row.querySelectorAll<HTMLElement>("span")) {
                    const css = getComputedStyle(part);
                    if (!part.textContent?.trim()) continue;
                    if (part.getBoundingClientRect().right > end + 0.5) spill.push(part.textContent);
                    faces.add(css.fontFamily);
                    if (css.textTransform !== "none" || css.fontStyle !== "normal")
                      odd.push(`${part.className}: ${css.textTransform} ${css.fontStyle}`);
                    for (const kind of ["name", "description", "hint"] as const)
                      if (part.classList.contains(`acpmux-slash-${kind}`)) sizes[kind]!.add(css.fontSize);
                  }
                }
                return {
                  viewport: { width: innerWidth, height: innerHeight },
                  shell: { top: s.top, bottom: s.bottom, left: s.left, right: s.right },
                  box: { top: b.top, bottom: b.bottom, left: b.left, right: b.right },
                  above: b.top - s.bottom,
                  below: s.top - b.bottom,
                  radius: { list: radius(shell), box: radius(box) },
                  shown: shown.length,
                  total: rows.length,
                  spill,
                  faces: [...faces],
                  field: getComputedStyle(field).fontFamily,
                  odd,
                  sizes: Object.fromEntries(Object.entries(sizes).map(([kind, set]) => [kind, [...set]])),
                };
              }, stage.box);
              console.log(
                `slash-menu-fits: ${stage.name} ${size.width}x${size.height} ${look.name} ${JSON.stringify(found)}`,
              );
              // Wholly inside the window, a margin off each edge.
              expect(found.shell.top).toBeGreaterThanOrEqual(4);
              expect(found.shell.bottom).toBeLessThanOrEqual(found.viewport.height - 4);
              expect(found.shell.left).toBeGreaterThanOrEqual(0);
              expect(found.shell.right).toBeLessThanOrEqual(found.viewport.width);
              // 6 px beside the box, on its edges.
              const gap = found.above >= 0 ? found.above : found.below;
              expect(Math.abs(gap - 6)).toBeLessThanOrEqual(1.5);
              expect(Math.abs(found.shell.left - found.box.left)).toBeLessThanOrEqual(1);
              expect(Math.abs(found.shell.right - found.box.right)).toBeLessThanOrEqual(1);
              // The box's own corners.
              expect(Math.abs(found.radius.list - found.radius.box)).toBeLessThanOrEqual(1);
              // A real list, not a sliver.
              expect(found.shown).toBeGreaterThanOrEqual(3);
              // One typeface, upright, in normal case; the command and what it does at one size.
              expect(found.spill).toEqual([]);
              expect(found.faces).toEqual([found.field]);
              expect(found.odd).toEqual([]);
              expect(found.sizes.name!.length).toBe(1);
              expect(found.sizes.description).toEqual(found.sizes.name);
              for (const hint of found.sizes.hint!) expect(hint).toBe(found.sizes.name![0]!);
              expect(errors).toEqual([]);
            } finally {
              await page.close();
            }
          });
  });
});
