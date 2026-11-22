// cmux-web-test-timeout: 300
// The real mic's context menu retains only its opener's hover tone until dismissal.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("dictation-popup-hover.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const) {
      browsers.set(name, await engine.launch({ headless: true }));
    }
    await warmGalleryFrame(vite, "agent-pane.dictation", { browser: browsers.get("chromium") });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });
  const settled = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.effect?.getTiming().iterations === Infinity || animation.playState !== "running",
        ),
    );
  const states = [
    ["idle", ".acpmux-mic"],
    ["listening", ".acpmux-mic"],
  ] as const;
  for (const engine of ["chromium", "webkit"])
    for (const theme of ["Catppuccin Mocha", "Catppuccin Latte"])
      for (const [variant, selector] of states) {
        test(`${engine} ${theme} ${variant} ${selector}: retained tone, stable bounds, cleanup`, async () => {
          const page = await browsers
            .get(engine)!
            .newPage({ viewport: { width: 760, height: 400 }, deviceScaleFactor: 2 });
          try {
            const port = (vite.httpServer!.address() as { port: number }).port;
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame("agent-pane.dictation", {
                variant,
                theme,
                frame: "component",
                width: 520,
              })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            const control = page.locator(selector);
            const read = () =>
              page.locator(".acpmux-composer-actions").evaluate((row) =>
                [row, ...row.querySelectorAll("button")].map((element) => {
                  const style = getComputedStyle(element);
                  const box = element.getBoundingClientRect();
                  return {
                    name: element.className,
                    fill: style.backgroundColor,
                    ink: style.color,
                    box: [box.x, box.y, box.width, box.height],
                  };
                }),
              );
            await page.mouse.move(1, 1);
            await settled(page);
            const rest = await read();
            await control.hover();
            await settled(page);
            const hovered = await read();
            // Right-click the glyph itself, so nested SVG targets are covered too.
            await control.locator("svg").click({ button: "right" });
            const menu = page.getByRole("menuitem", { name: "Hide Dictation Button" });
            await menu.hover();
            await settled(page);
            const open = await read();
            expect(await control.getAttribute("data-popup-open")).toBe("");
            expect(await page.locator(".acpmux-composer-actions button[data-popup-open]").count()).toBe(1);
            const index = hovered.findIndex((item) => item.name.split(" ").includes(selector.slice(1)));
            expect(index).toBeGreaterThan(0);
            expect(hovered[index]!.fill).not.toBe(rest[index]!.fill);
            const mismatches = open.filter(
              (item, i) => item.fill !== hovered[i]!.fill || item.ink !== hovered[i]!.ink,
            ).length;
            const shift = Math.max(
              ...open.flatMap((item, i) => item.box.map((value, axis) => Math.abs(value - rest[i]!.box[axis]!))),
            );
            console.log(
              `dictation-popup ${engine} ${theme} ${variant} ${selector}: mismatches=${mismatches} shiftPx=${shift}`,
            );
            if (process.env.FAST_CHECKS_OUT) {
              await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
              await page.screenshot({
                path: path.join(
                  process.env.FAST_CHECKS_OUT,
                  `dictation-${engine}-${theme.replaceAll(" ", "-")}-${variant}-${selector.slice(1)}.png`,
                ),
              });
            }
            expect(open).toEqual(hovered);
            expect(shift).toBe(0);
            await page.mouse.click(1, 1);
            await page.waitForFunction(() => !document.querySelector("[data-popup-open]"));
            await settled(page);
            expect(await read()).toEqual(rest);
          } finally {
            await page.close();
          }
        });
      }
});
