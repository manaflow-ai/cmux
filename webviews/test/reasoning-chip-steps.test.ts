// The Reasoning chip held before a session reports (#20946: the New Tab composer, a new chat) steps
// down as the chat's own does (composerRowFit.ts effortShort): a narrow composer names the level's
// short form whole ("Med"), never a cut one ("M…" at 300 px, cg-ui-coord 2026-10-15). A wide one
// names it in full.
//
// The gallery's real panes in Chromium: `agent-pane.new-tab` (`reasoning-chip`) and
// `agent-pane.composer` (`new-chat-reasoning`), and a New Tab whose agent reported its levels
// (`agent-pane.narrow` `new-tab`, "Medium Fast"), at 760, 400 and 300 px.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("reasoning-chip-steps.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("reasoning-chip-steps: skipping (run `bunx playwright install chromium`)");
    describe.skip("reasoning chip steps", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}&frame=component&width=${width}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 800, height: 600 } });
    await warm.goto(url("agent-pane.composer", "new-chat-reasoning", 760));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: width + 40, height: 640 } });
    await page.goto(url(entry, variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".acpmux-chips .acpmux-effort").waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(200);
    return page;
  };

  /** Runs in the page: the effort chip's drawn labels (text and ::before) and any it cuts. */
  function effortChip() {
    const button = document.querySelector<HTMLElement>(".acpmux-chips .acpmux-effort .acpmux-picker-button")!;
    const shown = (element: Element) =>
      element.getClientRects().length > 0 && getComputedStyle(element).visibility === "visible";
    const box = button.getBoundingClientRect();
    const labels: string[] = [];
    const cut: string[] = [];
    const parts: Element[] = [];
    const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode())
      if (node.textContent?.trim() && node.parentElement && shown(node.parentElement)) {
        labels.push(node.textContent.trim());
        parts.push(node.parentElement);
      }
    for (const element of [button, ...button.querySelectorAll("*")]) {
      const content = getComputedStyle(element, "::before").content;
      if (/^".+"$/.test(content) && shown(element)) {
        labels.push(content.slice(1, -1).trim());
        parts.push(element);
      }
    }
    // The visible parts only: the chip lays its other forms out of the row, hidden, so they still
    // measure (composerRowFit.ts), and its own scroll width counts them.
    for (const element of parts) {
      const style = getComputedStyle(element);
      const value = element.textContent?.trim() || style.content;
      if (element.scrollWidth > element.clientWidth + 0.5 && style.display !== "inline")
        cut.push(`"${value}" overflows its box by ${element.scrollWidth - element.clientWidth} px`);
      if (style.textOverflow === "ellipsis" && element.scrollWidth > element.clientWidth + 0.5)
        cut.push(`"${value}" ends in an ellipsis`);
      const rect = element.getBoundingClientRect();
      if (rect.left < box.left - 0.5 || rect.right > box.right + 0.5) cut.push(`"${value}" runs outside its chip`);
    }
    return { labels, cut };
  }

  const held: Record<number, string> = { 760: "Medium", 400: "Med", 300: "Med" };
  // Its level is one option named "Medium Fast": the short form is its first word's.
  const reported: Record<number, string> = { 760: "Medium Fast", 400: "Med", 300: "Med" };
  const cases: [string, string, string, Record<number, string>][] = [
    ["New Tab", "agent-pane.new-tab", "reasoning-chip", held],
    ["new chat", "agent-pane.composer", "new-chat-reasoning", held],
    ["New Tab, reported", "agent-pane.narrow", "new-tab", reported],
  ];
  for (const [where, entry, variant, expected] of cases)
    for (const width of [760, 400, 300])
      test(`${where} at ${width} px: the reasoning chip reads "${expected[width]}" whole`, async () => {
        const page = await open(entry, variant, width);
        const chip = await page.evaluate(effortChip);
        expect(chip.cut, "no label cut").toEqual([]);
        expect(chip.labels, "the level's whole name").toEqual([expected[width]!]);
        await page.close();
      });
});
