// cmux-web-test-timeout: 240
// Lawrence, via Leo 2026-10-28: "lawrence says search feels confusing here in the model picker".
// Real Chromium lays out the compact model menu on his machine (src/gallery/fixtures/modelSearch.ts)
// searched for "sol 6.1": matches sit under their harness, the rail keeps only those harnesses and
// lights none, rows that read the same show their ids, no row cuts its name or detail, and Enter
// picks the top match.
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
    await page.waitForSelector(".acpmux-quick-search input");
    await page.fill(".acpmux-quick-search input", query);
    await page.waitForSelector(".acpmux-quick-found, .acpmux-quick-note");
    return page;
  }

  /// What the menu shows: its headings, rail tabs, rows (name, detail, id) and any cut text.
  const read = (page: Page) =>
    page.evaluate(() => {
      const menu = document.querySelector<HTMLElement>(".acpmux-quick-menu")!;
      const cut = (element: Element | null) => !!element && element.scrollWidth > element.clientWidth + 1;
      const rows = [...menu.querySelectorAll<HTMLElement>(".acpmux-quick-found")].map((row) => ({
        name: row.querySelector(".acpmux-menu-label")?.textContent ?? "",
        detail: row.querySelector(".acpmux-quick-value")?.textContent ?? "",
        id: row.querySelector(".acpmux-quick-id")?.textContent ?? "",
        heading: row.closest(".ui-menu-group")?.querySelector(".ui-menu-group-label")?.textContent ?? "",
        title: row.title,
        cut: cut(row.querySelector(".acpmux-menu-label")) || cut(row.querySelector(".acpmux-quick-value")),
        height: row.getBoundingClientRect().height,
      }));
      return {
        headings: [...menu.querySelectorAll(".ui-menu-group-label")].map((label) => label.textContent),
        tabs: [...menu.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab")].map((tab) => ({
          name: tab.getAttribute("aria-label"),
          pressed: tab.getAttribute("aria-pressed") === "true",
        })),
        rows,
        note: menu.querySelector(".acpmux-quick-note")?.textContent ?? "",
        noteCut: (() => {
          const note = menu.querySelector<HTMLElement>(".acpmux-quick-note");
          return !!note && (note.scrollHeight > note.clientHeight + 1 || note.scrollWidth > note.clientWidth + 1);
        })(),
      };
    });

  test("matches sit under their harness, and the rail keeps only those harnesses, none lit", async () => {
    const page = await searched("sol 6.1");
    const { headings, tabs, rows } = await read(page);
    expect(headings).toEqual(["Codex", "OpenCode", "Pi"]);
    expect(tabs.map((tab) => tab.name)).toEqual(["Codex", "OpenCode", "Pi"]);
    expect(tabs.some((tab) => tab.pressed)).toBe(false);
    for (const row of rows) expect(headings).toContain(row.heading);
    expect(rows.every((row) => !row.detail.includes(row.heading))).toBe(true);
    await page.close();
  });

  test("rows that read the same show their ids, and no row cuts its name or detail", async () => {
    const page = await searched("sol 6.1");
    const { rows } = await read(page);
    const routes = rows.filter((row) => row.heading === "OpenCode" && row.name === "GPT-6.1 Sol");
    expect(routes).toHaveLength(2);
    expect(new Set(routes.map((row) => row.id)).size).toBe(2);
    expect(routes.every((row) => row.id !== "")).toBe(true);
    // Pi's OpenRouter names differ only at their end ("Thinking", "Mini", "Nano").
    const pi = rows.filter((row) => row.name.startsWith("OpenAI: GPT-6.1 Sol"));
    expect(pi.map((row) => row.name.split(" ")[3])).toEqual(["Thinking", "Mini", "Nano"]);
    expect(rows.filter((row) => row.cut)).toEqual([]);
    // Hover names a row whole: model, harness, provider and id.
    expect(rows.every((row) => row.title.includes(row.name) && row.title.includes(row.heading))).toBe(true);
    await page.close();
  });

  test("the one-list version names each row's harness beside its provider, uncut", async () => {
    const page = await searched("sol 6.1", "?look=flat");
    const { rows } = await read(page);
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.filter((row) => row.cut)).toEqual([]);
    expect(rows.filter((row) => row.name === "GPT-6.1 Sol").map((row) => row.detail.split(" · ")[0])).toEqual([
      "Codex",
      "OpenCode",
      "OpenCode",
      "Pi",
    ]);
    await page.close();
  });

  test("a search that finds nothing says what to do, and keeps every harness on the rail", async () => {
    const page = await searched("sol 9.9");
    const { note, noteCut, tabs } = await read(page);
    expect(note).toBe("No models match “sol 9.9”. Try part of a name, or clear the search to browse by harness.");
    // The note wraps and grows; it is never cut off (review of #27303).
    expect(noteCut).toBe(false);
    expect(tabs.length).toBeGreaterThan(3);
    expect(tabs.some((tab) => tab.pressed)).toBe(false);
    await page.close();
  });

  test("Enter picks the top match", async () => {
    const page = await searched("sol 6.1");
    await page.press(".acpmux-quick-search input", "Enter");
    await page.waitForFunction(() => (window as unknown as { picked: unknown[] }).picked.length > 0);
    const picked = await page.evaluate(() => (window as unknown as { picked: unknown[] }).picked);
    expect(picked[0]).toMatchObject({ harness: "codex", model: "gpt-6.1-sol" });
    await page.close();
  });
});
