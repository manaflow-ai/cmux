// cmux-web-test-timeout: 240
// Lawrence 2026-11-05, on the columns menu searched for "deepseek" ("DeepSeek V4 Pr...", "DeepSeek
// V4.1 F...", provider "Opencode-..."): "cant see full model name", "i want to be able to see which
// deepseek flash it is, like there's many versions of deepseek flash v4.1". Real Chromium lays out
// OpenCode's own DeepSeek list (src/gallery/fixtures/modelSearch.ts): every model and provider name
// reads whole (the menu grows to fit, then wraps; it never clips), the provider reads "OpenCode Go",
// rows that share a name show their model id under it, and every row names its provider to assistive tech
// (Lucas 2026-11-11: the tooltip is the model's name alone). A narrowed menu puts the chosen row's check in
// the star's place, so the star replaces it on hover and never sits on it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("model-picker-full-names.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("model-picker-full-names: skipping (run `bunx playwright install chromium`)");
    describe.skip("model picker full names", () => test("chromium", () => {}));
    return;
  }
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
    await warmViteServer(vite, "/test/browser/model-search.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function searched(query: string, catalog: string, width = 1200): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/model-search.html?catalog=${catalog}`);
    await page.click(".acpmux-picker-button");
    await page.waitForSelector(".acpmux-cols-search input[type=search]");
    await page.fill(".acpmux-cols-search input[type=search]", query);
    await page.waitForSelector(".acpmux-cols [role=listbox] .acpmux-cols-group");
    return page;
  }

  /// Each model row and each provider row: its name, whether any of it is cut off, its visible id
  /// line, the provider it names to assistive tech, and (a model row) its search group's heading.
  const read = (page: Page) =>
    page.evaluate(() => {
      const menu = document.querySelector<HTMLElement>(".acpmux-cols")!;
      const cut = (label: HTMLElement) =>
        label.scrollWidth > label.clientWidth + 1 || label.scrollHeight > label.clientHeight + 1;
      const row = (element: HTMLElement) => {
        const label = element.querySelector<HTMLElement>(".acpmux-cols-name")!;
        const id = element.querySelector<HTMLElement>(".acpmux-cols-id");
        const box = element.getBoundingClientRect();
        const text = label.getBoundingClientRect();
        return {
          name: label.textContent ?? "",
          cut: cut(label) || text.right > box.right + 1 || (!!id && cut(id)),
          id: id?.textContent ?? "",
          provider: element.getAttribute("aria-description") ?? "",
        };
      };
      return {
        width: menu.getBoundingClientRect().width,
        fontSize: parseFloat(getComputedStyle(menu).fontSize),
        models: (() => {
          let heading = "";
          return [...menu.querySelector<HTMLElement>("[role=listbox]")!.children].flatMap((child) => {
            if (child.matches(".acpmux-cols-group")) heading = child.textContent ?? "";
            return child.matches("[role=option]") ? [{ ...row(child as HTMLElement), heading }] : [];
          });
        })(),
        providers: [...menu.querySelectorAll<HTMLElement>(".acpmux-cols-tune .acpmux-cols-row")].map(row),
      };
    });

  test("every DeepSeek model and provider name reads whole", async () => {
    const page = await searched("deepseek", "deepseek");
    const { models, providers } = await read(page);
    const names = models.map((model) => model.name);
    expect(names).toEqual(
      expect.arrayContaining(["DeepSeek V4.1 Flash", "DeepSeek V4.1 Flash Free", "DeepSeek V4.1 Flash 1017"]),
    );
    expect(models.filter((model) => model.cut).map((model) => model.name)).toEqual([]);
    // The top match, DeepSeek V4 Pro, runs through OpenCode Go and OpenRouter.
    expect(providers.map((provider) => provider.name)).toEqual(expect.arrayContaining(["OpenCode Go", "OpenRouter"]));
    expect(providers.filter((provider) => provider.cut).map((provider) => provider.name)).toEqual([]);
    await page.close();
  });

  test("the menu grows to fit, within its cap, and long names wrap instead of clipping", async () => {
    const page = await searched("sol", "sol");
    const { width, fontSize, models } = await read(page);
    expect(width).toBeLessThanOrEqual(40 * fontSize + 1);
    // "GPT-6.1 Sol Ultracode (preview, extended reasoning)" is longer than the cap: it wraps.
    const long = models.find((model) => model.name.startsWith("GPT-6.1 Sol Ultracode"));
    expect(long?.cut).toBe(false);
    expect(models.filter((model) => model.cut).map((model) => model.name)).toEqual([]);
    await page.close();
  });

  test("a narrow window still shows every name whole", async () => {
    const page = await searched("deepseek", "deepseek", 420);
    const { width, models } = await read(page);
    expect(width).toBeLessThanOrEqual(420);
    expect(models.filter((model) => model.cut).map((model) => model.name)).toEqual([]);
    await page.close();
  });

  test("rows that share a name show their model id, and every row names its provider", async () => {
    const page = await searched("sol 6.1", "sol");
    const { models } = await read(page);
    const twins = models.filter((model) => model.name === "GPT-6.1 Sol" && model.heading === "OpenCode");
    expect(twins).toHaveLength(2);
    expect(twins.map((model) => model.id).sort()).toEqual([
      "openrouter/openai/gpt-6.1-sol",
      "openrouter/openai/gpt-6.1-sol-20261015",
    ]);
    // A name no other row shares needs no id line.
    expect(models.find((model) => model.name === "GPT-6.1 Sol Fast")?.id).toBe("");
    // A row names the provider it lands to assistive tech, as its tooltip once did.
    expect(twins.every((model) => model.provider.length > 0)).toBe(true);
    await page.close();
  });

  test("a narrowed menu puts the chosen row's check in the star's place, and widening brings it back", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/model-search.html`);
    await page.click(".acpmux-picker-button");
    const chosen = page.locator('.acpmux-cols [role=listbox] [role=option][aria-selected="true"]').first();
    await chosen.waitFor();
    // What a drag on the menu's edge sets (startResize): the width, and the drag's floor (260 px) in place of
    // the default's 28.5em one. The list's size change alone must re-measure the rows: the ResizeObserver
    // re-measures after it; wait for the row's answer, then read it.
    const marks = async (width: number, cover: string | undefined) => {
      await page.evaluate((w) => {
        const menu = document.querySelector<HTMLElement>(".acpmux-cols")!;
        menu.style.width = `${w}px`;
        menu.style.minWidth = "260px";
      }, width);
      await page.waitForFunction(
        (want) =>
          document.querySelector<HTMLElement>('.acpmux-cols [role=listbox] [role=option][aria-selected="true"]')
            ?.dataset.starCover === (want ?? undefined),
        cover ?? null,
      );
      return chosen.evaluate((row) => ({
        check: row.querySelector(".acpmux-cols-check")!.getBoundingClientRect().toJSON() as DOMRect,
        star: row.querySelector(".acpmux-cols-star")!.getBoundingClientRect().toJSON() as DOMRect,
      }));
    };
    const wide = await marks(400, undefined);
    expect(wide.check.right).toBeLessThan(wide.star.left);
    const narrow = await marks(260, "check");
    expect(Math.abs(narrow.check.left - narrow.star.left)).toBeLessThan(1);
    expect(Math.abs(narrow.check.right - narrow.star.right)).toBeLessThan(1);
    await chosen.hover();
    expect(await chosen.locator(".acpmux-cols-check").evaluate((check) => getComputedStyle(check).visibility)).toBe(
      "hidden",
    );
    await page.mouse.move(0, 0);
    const again = await marks(400, undefined);
    expect(again.check.right).toBeLessThan(again.star.left);
    await page.close();
  });
});
