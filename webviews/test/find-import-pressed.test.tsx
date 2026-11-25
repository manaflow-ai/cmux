// Real React component and browser input: a held button must differ from hover without moving its box.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator } from "playwright";
import { type ViteDevServer, createServer } from "vite";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("find-import-pressed.test.tsx", async () => {
  // Reduce Motion (desktop.css) gives every property a 0.01 ms transition, so a frame can still hold
  // the hover or press change mid-transition, read as its oklab interpolation (0.1 on its way to
  // 0.15). Feedback stays immediate: no transition may last 1 ms or more. Read once they settle.
  const paint = (button: Locator) =>
    button.evaluate(async (element) => {
      await window.cmuxPaintFrame();
      const running = element.getAnimations();
      for (const animation of running) {
        const duration = Number(animation.effect?.getComputedTiming().duration ?? 0);
        if (!(duration < 1)) throw new Error(`press or hover feedback animates for ${duration} ms`);
      }
      await Promise.allSettled(running.map((animation) => animation.finished));
      if (running.length) await window.cmuxPaintFrame();
      const style = getComputedStyle(element);
      return { background: style.backgroundColor, color: style.color, opacity: style.opacity };
    });
  let browser: Browser;
  let vite: ViteDevServer;
  beforeAll(async () => {
    setDefaultTimeout(120_000);
    vite = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/find-import-pressed.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["light", "dark"] as const) {
    describe(theme, () => {
      const setup = async (canStep = true) => {
        const page = await browser.newPage({ colorScheme: theme, reducedMotion: "reduce" });
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/find-import-pressed.html?canStep=${canStep}`);
        await page.getByRole("button", { name: "Match case", exact: true }).waitFor();
        await installPaintedFrames(page);
        return page;
      };
      for (const name of [
        "Previous",
        "Next",
        "Close",
        "Match case",
        "Toggle Replace",
        "Replace",
        "All",
        "Import",
        "Not Now",
      ]) {
        test(`${name} responds while held and restores its hover paint`, async () => {
          const page = await setup();
          try {
            const button = page.getByRole("button", { name, exact: true });
            await button.hover();
            const hovered = await paint(button);
            const box = await button.boundingBox();
            if (!box) throw new Error(`${name} has no box`);
            await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
            await page.mouse.down();
            const held = await paint(button);
            expect(held).not.toEqual(hovered);
            expect(await button.boundingBox()).toEqual(box);
            if (await button.evaluate((element) => element.matches(".find-pill__button")))
              expect(await button.getAttribute("data-press-active")).toBe("true");
            await page.mouse.up();
            const restored = await paint(button);
            expect((await button.getAttribute("style")) ?? "").toBe("");
            expect(await button.getAttribute("data-press-active")).toBeNull();
            expect(restored).toEqual(hovered);
          } finally {
            await page.close();
          }
        });
      }
      test("dragging off Next cancels its action and clears press feedback", async () => {
        const page = await setup();
        try {
          const button = page.getByRole("button", { name: "Next", exact: true });
          const count = page.locator("[data-next-count]");
          // Prove the fixture observes the component's action before checking cancellation.
          await button.click();
          expect(await count.textContent()).toBe("1");
          await button.hover();
          await page.mouse.down();
          expect(await button.getAttribute("data-press-active")).toBe("true");
          await page.mouse.move(2, 2);
          expect(await button.getAttribute("data-press-active")).toBeNull();
          await page.mouse.up();
          expect(await count.textContent()).toBe("1");
          expect(await button.getAttribute("data-press-active")).toBeNull();
        } finally {
          await page.close();
        }
      });
      test("disabled Find actions keep their paint while held", async () => {
        const page = await setup(false);
        try {
          for (const name of ["Previous", "Next", "Replace", "All"]) {
            const button = page.getByRole("button", { name, exact: true });
            const box = await button.boundingBox();
            if (!box) throw new Error(`${name} has no box`);
            await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
            const before = await paint(button);
            await page.mouse.down();
            expect(await paint(button)).toEqual(before);
            await page.mouse.up();
          }
        } finally {
          await page.close();
        }
      });
      test("keyboard focus remains visible and Space gives press feedback", async () => {
        const page = await setup();
        try {
          const button = page.getByRole("button", { name: "Import", exact: true });
          await page.keyboard.press("Tab");
          await button.focus();
          expect(await button.evaluate((element) => element.matches(":focus-visible"))).toBe(true);
          expect(await button.evaluate((element) => getComputedStyle(element).outlineStyle)).toBe("solid");
          const before = await paint(button);
          await page.keyboard.down("Space");
          expect(await paint(button)).not.toEqual(before);
          await page.keyboard.up("Space");
          expect(await paint(button)).toEqual(before);
        } finally {
          await page.close();
        }
      });
      test("no-match status uses the host's danger token", async () => {
        const page = await setup(false);
        try {
          const count = page.locator(".find-pill__count");
          const expected = await page.evaluate(() => {
            const probe = document.createElement("span");
            probe.style.color = "var(--cmux-app-danger)";
            document.body.append(probe);
            const color = getComputedStyle(probe).color;
            probe.remove();
            return color;
          });
          expect(await count.evaluate((element) => getComputedStyle(element).color)).toBe(expected);
        } finally {
          await page.close();
        }
      });
    });
  }
});
