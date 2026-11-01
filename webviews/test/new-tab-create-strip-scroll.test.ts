import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-create-strip-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let utilities = "";
  beforeAll(async () => {
    const { compileTailwind } = await import("../scripts/agent-pane/tailwindCompile.mjs");
    utilities = await compileTailwind(path.join(webviews, "src/agent-session/acpmux/tailwind.css"));
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/new-tab-picker.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const key of ["ArrowDown", "Tab"]) {
    test(`${key} keeps each selected create action inside the suggestion viewport`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: 360 }, reducedMotion: "reduce" });
      try {
        await page.goto(
          `http://127.0.0.1:${port}/test/browser/new-tab-picker.html?template=threads&crowdedSuggestions`,
        );
        await page.addStyleTag({ content: utilities });
        await page.locator(".nt-field").waitFor();
        await page.evaluate(() => document.getElementById("root")!.classList.add("acpmux-shell"));
        await page.locator(".nt-field .ProseMirror").fill("project");
        await page.locator(".nt-create-strip").waitFor();
        const ordinary = await page.locator(".nt-rows > .nt-row").count();
        expect(ordinary).toBeGreaterThan(3);
        expect(await page.locator(".nt-create-strip-item").count()).toBe(3);
        const initial = await page.evaluate(() => {
          const list = document.querySelector<HTMLElement>(".nt-rows")!;
          return {
            overflow: list.scrollHeight - list.clientHeight,
            pageScroll: document.querySelector(".nt-screen")!.scrollTop,
          };
        });
        expect(initial.overflow).toBeGreaterThan(24);
        for (let index = 0; index < ordinary - 1; index++) await page.keyboard.press(key);
        for (let index = 0; index < 3; index++) {
          await page.keyboard.press(key);
          await page.waitForFunction(
            (selectedIndex) =>
              document.querySelector(".nt-create-strip-item.is-selected") ===
              document.querySelectorAll(".nt-create-strip-item")[selectedIndex],
            index,
          );
          const geometry = await page.evaluate(() => {
            const list = document.querySelector(".nt-rows")!.getBoundingClientRect();
            const selected = document.querySelector(".nt-create-strip-item.is-selected")!.getBoundingClientRect();
            return {
              top: selected.top - list.top,
              bottom: list.bottom - selected.bottom,
              focused: document.activeElement?.closest(".nt-field") !== null,
              pageScroll: document.querySelector(".nt-screen")!.scrollTop,
            };
          });
          console.log("create-strip-scroll", key, index, JSON.stringify(geometry));
          if (index === 0 && key === "ArrowDown" && process.env.CMUX_CAPTURE_STRIP_DIR) {
            mkdirSync(process.env.CMUX_CAPTURE_STRIP_DIR, { recursive: true });
            await page.screenshot({ path: path.join(process.env.CMUX_CAPTURE_STRIP_DIR, "new-tab-strip.png") });
          }
          expect(geometry.focused).toBe(true);
          expect(geometry.pageScroll).toBe(initial.pageScroll);
          expect(geometry.top).toBeGreaterThanOrEqual(-1);
          expect(geometry.bottom).toBeGreaterThanOrEqual(-1);
        }
      } finally {
        await page.close();
      }
    });
  }
});
