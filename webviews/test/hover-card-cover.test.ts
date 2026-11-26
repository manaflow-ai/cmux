// A hover card never covers the row text it describes (ui/Tooltip.tsx Tooltip and AnchoredCard, the
// shared layer under SubagentChipPreview, chips/FactsHoverCard.tsx WithFacts and every plain
// tooltip). Leo, 2026-11-22, on a restored chat whose subagent hover card sat on the row's words:
// "and more bullshit somehow happened here". It opens above or below the row's line, flips to the
// other side when there is no room, and is never placed beside its chip on the row itself.
//
// test/browser/hover-card-cover.harness.tsx: a scrolled transcript of one-line rows, a chip in the
// middle of one. Every surface, with its row at the top and at the bottom of the scroll viewport, in a
// normal and a narrow pane, with a short and a long card: the open card's box intersects none of the
// row's text boxes.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("hover-card-cover.test.ts", async () => {
  setDefaultTimeout(300_000);
  const PAGE = "/test/browser/hover-card-cover.html";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Box = { left: number; top: number; right: number; bottom: number };
  const hits = (a: Box, b: Box) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

  test("no hover card covers its row's text, at the top or bottom of the transcript, narrow, long", async () => {
    const page = await browser.newPage({ viewport: { width: 900, height: 420 } });
    const overlaps: string[] = [];
    let cases = 0;
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${PAGE}`);
      await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
      for (const kind of ["card", "facts", "tip"] as const)
        for (const at of ["top", "bottom"] as const)
          for (const pane of [760, 300])
            for (const long of [false, true]) {
              const name = `${kind} at ${at}, ${pane}px pane, ${long ? "long" : "short"}`;
              await page.mouse.move(890, 2);
              await page.evaluate(
                (props) => (window as unknown as { __mount(p: unknown): Promise<void> }).__mount(props),
                { kind, at, pane, long },
              );
              await page.locator("[data-hover-chip]").hover();
              const card = page.locator(kind === "facts" ? ".ui-facts-card" : ".ui-tooltip").last();
              await card.waitFor({ state: "visible", timeout: 5_000 });
              // Placed (Base UI positions after a frame or two).
              await page.evaluate(
                () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
              );
              const box = await card.evaluate((element) => {
                const rect = element.getBoundingClientRect();
                return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
              });
              const text = await page.evaluate(() => (window as unknown as { __rowText(): Box[] }).__rowText());
              expect(text.length).toBeGreaterThan(0);
              cases++;
              if (text.some((line) => hits(box, line)))
                overlaps.push(`${name}: card ${JSON.stringify(box)} over row ${JSON.stringify(text[0])}`);
            }
    } finally {
      await page.close();
    }
    console.log(`hover-card-cover: ${overlaps.length} of ${cases} cases cover their row's text`);
    for (const line of overlaps) console.log(`  ${line}`);
    expect(cases).toBe(24);
    expect(overlaps).toEqual([]);
  });
});
