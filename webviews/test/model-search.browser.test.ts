// cmux-web-test-timeout: 240
// Lawrence, via Leo 2026-10-28: "lawrence says search feels confusing here in the model picker".
// Real Chromium lays out the compact model menu on his machine (src/gallery/fixtures/modelSearch.ts)
// searched for "sol 6.1": matches sit under their harness, the full rail stays available with none
// selected, compact labels keep their full names in tooltips, and Return lands the top match.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("model-search.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("model-search: skipping (run `bunx playwright install chromium`)");
    describe.skip("model search", () => test("chromium", () => {}));
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

  async function searched(query: string, look = ""): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 640, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/model-search.html${look}`);
    await page.click(".acpmux-picker-button");
    await page.waitForSelector(".acpmux-cols-search input[type=search]");
    await page.fill(".acpmux-cols-search input[type=search]", query);
    await page.waitForSelector(
      ".acpmux-cols [role=listbox] .acpmux-cols-group, .acpmux-cols [role=listbox] .acpmux-cols-note",
    );
    return page;
  }

  /// Search groups are sibling headings in the models column. Long names may ellipsize;
  /// their full text stays in the title, and their boxes must stay inside the row.
  const read = (page: Page) =>
    page.evaluate(() => {
      const menu = document.querySelector<HTMLElement>(".acpmux-cols")!;
      const models = menu.querySelector<HTMLElement>("[role=listbox]")!;
      let heading = "";
      const rows = [...models.children].flatMap((child) => {
        if (child.matches(".acpmux-cols-group")) heading = child.textContent ?? "";
        if (!child.matches("[role=option]")) return [];
        const row = child as HTMLElement;
        const label = row.querySelector<HTMLElement>(".acpmux-cols-name")!;
        const area = row.getBoundingClientRect();
        const text = label.getBoundingClientRect();
        return [
          {
            name: label.textContent ?? "",
            heading,
            title: row.title,
            labelInside: text.left >= area.left && text.right <= area.right + 1,
            ellipsis: getComputedStyle(label).textOverflow,
            height: area.height,
          },
        ];
      });
      const note = models.querySelector<HTMLElement>(".acpmux-cols-note");
      return {
        headings: [...models.querySelectorAll(".acpmux-cols-group")].map((label) => label.textContent),
        tabs: [...menu.querySelectorAll<HTMLElement>(".acpmux-cols-tab[role=tab]")].map((tab) => ({
          name: tab.getAttribute("aria-label"),
          selected: tab.getAttribute("aria-selected") === "true",
        })),
        rows,
        note: note?.textContent ?? "",
        noteCut: !!note && (note.scrollHeight > note.clientHeight + 1 || note.scrollWidth > note.clientWidth + 1),
      };
    });

  test("matches sit under their harness while every rail tab stays available, none selected", async () => {
    const page = await searched("sol 6.1");
    const { headings, tabs, rows } = await read(page);
    expect(headings).toEqual(["Codex", "OpenCode", "Pi"]);
    expect(tabs[0]?.name).toBe("Starred");
    expect(tabs.map((tab) => tab.name)).toEqual(
      expect.arrayContaining(["Claude Code", "Codex", "OpenCode", "Pi", "Gemini CLI"]),
    );
    expect(tabs.some((tab) => tab.selected)).toBe(false);
    for (const row of rows) expect(headings).toContain(row.heading);
    await page.close();
  });

  test("compact labels stay inside their rows and tooltips name every match whole", async () => {
    const page = await searched("sol 6.1");
    const { rows } = await read(page);
    expect(rows.length).toBeGreaterThan(3);
    // Pi's OpenRouter names differ only at their end (Thinking, Mini, Nano).
    const pi = rows.filter((row) => row.name.startsWith("OpenAI: GPT-6.1 Sol"));
    expect(pi.map((row) => row.name.split(" ")[3])).toEqual(["Thinking", "Mini", "Nano"]);
    expect(rows.every((row) => row.labelInside && row.ellipsis === "ellipsis")).toBe(true);
    expect(rows.every((row) => row.height >= 26)).toBe(true);
    expect(rows.every((row) => row.title.includes(row.name) && row.title.includes(row.heading))).toBe(true);
    await page.close();
  });

  test("same-named OpenCode routes remain separate picks", async () => {
    const picked: string[] = [];
    for (const index of [0, 1]) {
      const page = await searched("sol 6.1");
      const { rows } = await read(page);
      const indexes = rows.flatMap((row, at) => (row.heading === "OpenCode" && row.name === "GPT-6.1 Sol" ? [at] : []));
      expect(indexes).toHaveLength(2);
      await page.locator(".acpmux-cols [role=listbox] [role=option]").nth(indexes[index]!).click();
      // A click lands the pick at once and keeps the menu open; Return then only closes it.
      expect(await page.locator(".acpmux-cols").count(), "a click keeps the menu open").toBe(1);
      expect(await page.evaluate(() => (window as unknown as { picked: unknown[] }).picked)).toHaveLength(1);
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-cols").waitFor({ state: "detached" });
      const landed = await page.evaluate(
        () => (window as unknown as { picked: { harness: string; model: string }[] }).picked,
      );
      expect(landed).toHaveLength(1);
      expect(landed[0]!.harness).toBe("opencode");
      picked.push(landed[0]!.model);
      await page.close();
    }
    expect(new Set(picked).size).toBe(2);
  });

  test("same-named routes have distinguishable tooltips", async () => {
    const page = await searched("sol 6.1");
    const { rows } = await read(page);
    const routes = rows.filter((row) => row.heading === "OpenCode" && row.name === "GPT-6.1 Sol");
    expect(routes).toHaveLength(2);
    // The old list showed IDs inline. Compact column labels need the tooltip to retain that
    // distinction when both routes have the same model name and provider.
    expect(new Set(routes.map((row) => row.title)).size).toBe(2);
    await page.close();
  });

  test("columns group matches by harness even when the old flat-search option is supplied", async () => {
    const page = await searched("sol 6.1", "?look=flat");
    const { headings, rows } = await read(page);
    expect(headings).toEqual(["Codex", "OpenCode", "Pi"]);
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.every((row) => headings.includes(row.heading))).toBe(true);
    await page.close();
  });

  test("an empty search result shows an unclipped note and keeps every rail tab", async () => {
    const page = await searched("sol 9.9");
    const { note, noteCut, tabs, rows } = await read(page);
    expect(note).toBe("No matching models");
    expect(rows).toEqual([]);
    expect(noteCut).toBe(false);
    expect(tabs[0]?.name).toBe("Starred");
    expect(tabs.length).toBeGreaterThan(3);
    expect(tabs.some((tab) => tab.selected)).toBe(false);
    await page.close();
  });

  test("Enter picks the top match", async () => {
    const page = await searched("sol 6.1");
    await page.press(".acpmux-cols-search input[type=search]", "Enter");
    await page.waitForFunction(() => (window as unknown as { picked: unknown[] }).picked.length > 0);
    const picked = await page.evaluate(() => (window as unknown as { picked: unknown[] }).picked);
    expect(picked).toHaveLength(1);
    await page.locator(".acpmux-cols").waitFor({ state: "detached" });
    expect(picked[0]).toMatchObject({ harness: "codex", model: "gpt-6.1-sol" });
    await page.close();
  });
});
