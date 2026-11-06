// cmux-web-test-timeout: 300
// The shipped columns picker must leave room for model names as chrome text grows.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-picker-scaling.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  const entry = "agent-pane.model-picker";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, entry, {
      browser: browsers.get("chromium"),
      params: { variant: "reported-codex-menu" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function open(engine: string, width = 1200, variant = "reported-codex-menu") {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 1000 } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height: 1000 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-cols-body").waitFor();
    return page;
  }

  const geometry = (page: Page) =>
    page.evaluate(() => {
      const box = (selector: string) => document.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
      return {
        model: box(".acpmux-cols-body > [role=listbox]").width,
        height: box(".acpmux-cols-frame").height,
        rail: box(".acpmux-cols-rail").width,
      };
    });

  for (const engine of ["chromium", "webkit"]) {
    for (const left of [16, 496])
      test(`${engine}: rail hints stay outside the picker at x=${left}, keeping the account hint's default position`, async () => {
        const page = await open(engine, 1200, "quick-menu");
        try {
          await page.keyboard.press("Escape");
          await page.locator(".acpmux-cols").waitFor({ state: "detached" });
          await page.addStyleTag({
            content: `.acpmux-model { position: fixed; left: ${left}px; top: 300px; margin: 0; }`,
          });
          await page.locator(".acpmux-model .acpmux-picker-button").click();
          await page.addScriptTag({
            type: "module",
            content: `
          import { installTooltips } from "/src/ui/titleTooltips.ts";
          if (!document.querySelector(".ui-title-tooltip")) installTooltips(document, { delay: 0 });
        `,
          });
          const tab = page.locator('.acpmux-cols-tab[aria-label="Codex"]');
          await tab.hover();
          const tip = page.locator(".ui-title-tooltip:visible");
          await tip.waitFor();
          const hint = (await tip.boundingBox())!;
          const rail = (await tab.boundingBox())!;
          const popup = (await page.locator(".acpmux-cols").boundingBox())!;
          if (left === 16) expect(hint.x).toBeGreaterThanOrEqual(popup.x + popup.width + 3);
          else expect(hint.x + hint.width).toBeLessThanOrEqual(popup.x - 3);
          expect(Math.abs(hint.y + hint.height / 2 - rail.y - rail.height / 2)).toBeLessThanOrEqual(1);
          const account = page.locator("button.acpmux-cols-profile");
          await account.hover();
          await tip.filter({ hasText: "Claude Max" }).waitFor();
          const accountHint = (await tip.boundingBox())!;
          const avatar = (await account.boundingBox())!;
          if (left === 16) expect(accountHint.x).toBe(4);
          else
            expect(Math.abs(accountHint.x + accountHint.width / 2 - avatar.x - avatar.width / 2)).toBeLessThanOrEqual(
              1,
            );
        } finally {
          await page.close();
        }
      });

    test(`${engine}: the model scrollbar only shows during scrolling and reaches the last row`, async () => {
      const page = await open(engine);
      try {
        await page.addScriptTag({
          type: "module",
          content: `
          import { installScrollers } from "/src/scrollers.ts";
          installScrollers(document);
        `,
        });
        const column = page.locator(".acpmux-cols-body > [role=listbox]");
        expect(await column.getAttribute("data-cmux-scrolling")).toBeNull();
        const thumbColor = () =>
          column.evaluate((node) => getComputedStyle(node, "::-webkit-scrollbar-thumb").backgroundColor);
        expect(await thumbColor()).toBe("rgba(0, 0, 0, 0)");
        const scroll = await column.evaluate((list) => {
          const node = list as HTMLElement;
          node.scrollTop = node.scrollHeight;
          const last = node
            .querySelectorAll<HTMLElement>("[role=option]")
            .item(node.querySelectorAll("[role=option]").length - 1);
          return {
            overflow: node.scrollHeight > node.clientHeight,
            width: node.offsetWidth - node.clientWidth,
            scrollbarWidth: getComputedStyle(node).scrollbarWidth,
            lastBottom: last.getBoundingClientRect().bottom,
            bottom: node.getBoundingClientRect().bottom,
          };
        });
        expect(scroll.overflow).toBe(true);
        expect(scroll.width).toBeLessThanOrEqual(9);
        expect(scroll.scrollbarWidth).toBe("auto");
        expect(scroll.lastBottom).toBeLessThanOrEqual(scroll.bottom + 1);
        await page.waitForFunction(() =>
          document.querySelector(".acpmux-cols-body > [role=listbox]")!.hasAttribute("data-cmux-scrolling"),
        );
        expect(await thumbColor()).not.toBe("rgba(0, 0, 0, 0)");
        await page.waitForFunction(
          () => !document.querySelector(".acpmux-cols-body > [role=listbox]")!.hasAttribute("data-cmux-scrolling"),
        );
        const bounds = (await column.boundingBox())!;
        await page.mouse.move(bounds.x + bounds.width - 2, bounds.y + bounds.height - 12);
        expect(await thumbColor()).toBe("rgba(0, 0, 0, 0)");
      } finally {
        await page.close();
      }
    });

    test(`${engine}: long model names truncate inside the scaled width cap`, async () => {
      const page = await open(engine, 1200, "long-model-name");
      try {
        for (const scale of [1, 1.5]) {
          await page.evaluate(
            (value) => document.documentElement.style.setProperty("--cmux-interface-scale", String(value)),
            scale,
          );
          const layout = await page.locator(".acpmux-cols").evaluate((menu) => {
            const name = menu.querySelector<HTMLElement>("[role=listbox] [role=option] .acpmux-cols-name")!;
            return {
              width: menu.getBoundingClientRect().width,
              rowTitle: name.closest<HTMLElement>("[role=option]")!.title,
              name: name.textContent,
              clipped: name.scrollWidth > name.clientWidth,
              ellipsis: getComputedStyle(name).textOverflow,
            };
          });
          expect(layout.width).toBeLessThanOrEqual(370.5 * scale + 0.5);
          expect(layout.clipped).toBe(true);
          expect(layout.ellipsis).toBe("ellipsis");
          expect(layout.rowTitle).toContain(layout.name!);
        }
      } finally {
        await page.close();
      }
    });

    test(`${engine}: default model names fit beside the star and check`, async () => {
      const page = await open(engine);
      try {
        expect((await geometry(page)).model).toBeGreaterThanOrEqual(185);
        expect((await page.locator(".acpmux-cols").boundingBox())!.width).toBeLessThanOrEqual(371);
        const labels = await page
          .locator(".acpmux-cols-body > [role=listbox] [role=option] .acpmux-cols-name")
          .evaluateAll((nodes) => nodes.map((node) => ({ width: node.clientWidth, content: node.scrollWidth })));
        expect(labels.length).toBeGreaterThan(4);
        expect(labels.every((label) => label.content <= label.width + 1)).toBe(true);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: an open picker grows with interface size and independent chrome text size`, async () => {
      const page = await open(engine);
      try {
        const initial = await geometry(page);
        await page.evaluate(() => document.documentElement.style.setProperty("--cmux-interface-scale", "1.5"));
        await page.waitForFunction(() => document.querySelector(".acpmux-cols")!.getBoundingClientRect().width > 540);
        const scaled = await geometry(page);
        expect(scaled.model).toBeGreaterThan(initial.model * 1.45);
        expect(scaled.rail).toBeGreaterThan(initial.rail * 1.45);
        expect(scaled.height).toBeGreaterThan(initial.height * 1.35);
        await page.evaluate(() => {
          document.documentElement.style.setProperty("--cmux-interface-scale", "1");
          document.documentElement.style.setProperty("--text-body", "20px");
        });
        await page.waitForFunction(
          () => document.querySelector(".acpmux-cols-body > [role=listbox]")!.getBoundingClientRect().width > 285,
        );
        expect((await geometry(page)).model).toBeGreaterThan(initial.model * 1.45);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: a narrow picker keeps readable names inside its columns`, async () => {
      const page = await open(engine, 360);
      try {
        await page.evaluate(() => document.documentElement.style.setProperty("--cmux-interface-scale", "1.5"));
        const layout = await page.locator(".acpmux-cols").evaluate((menu) => {
          const body = menu.querySelector<HTMLElement>(".acpmux-cols-body")!;
          const names = [...menu.querySelectorAll<HTMLElement>("[role=listbox] [role=option] .acpmux-cols-name")];
          return {
            width: menu.getBoundingClientRect().width,
            bodyWidth: body.clientWidth,
            contentWidth: body.scrollWidth,
            names: names.map((name) => ({
              width: name.clientWidth,
              content: name.scrollWidth,
              ellipsis: getComputedStyle(name).textOverflow,
            })),
          };
        });
        expect(layout.width).toBeLessThanOrEqual(360);
        expect(layout.contentWidth).toBeLessThanOrEqual(layout.bodyWidth + 1);
        expect(layout.names.length).toBeGreaterThan(4);
        expect(layout.names.every((name) => name.width > 0 && name.ellipsis === "ellipsis")).toBe(true);
      } finally {
        await page.close();
      }
    });
  }
});
