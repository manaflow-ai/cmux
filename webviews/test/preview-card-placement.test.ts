// l10n-allow-file: browser fixture prompts and replies, not shipped UI.
// The rail's preview card places itself before paint, from its own height (#28540): a card reused for
// another kind (a prompt's card, then a reply's: the full map's assistant marks) is placed after its
// clamp changes, never from the height it had before, and a card whose content resizes is placed
// again. On both rail edges (#24131: on the right the card ends at the rail's left).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("preview-card-placement.test.ts", async () => {
  const PROMPT =
    "Summarize the current rollout\nwhile keeping the useful failure details\nand compare it with the last release";
  const REPLY = Array.from(
    { length: 8 },
    (_, index) => `Paragraph ${index + 1} of the reply, long enough to wrap once or twice in the card.`,
  ).join("\n\n");
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/preview-card.html");
  });
  afterAll(async () => {
    await vite?.close();
  });

  const engines: Array<[string, BrowserType]> = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [engine, type] of engines)
    describe(engine, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await type.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });
      const open = async (): Promise<Page> => {
        const page = await browser!.newPage({ viewport: { width: 1000, height: 600 } });
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/preview-card.html`);
        await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
        return page;
      };
      const card = (page: Page, props: Record<string, unknown>) =>
        page.evaluate((p) => (window as unknown as { __card(p: unknown): Promise<void> }).__card(p), props);
      const placed = async (page: Page, side: "left" | "right") => {
        const { expected, actual } = await page.evaluate(() => {
          const w = window as unknown as {
            __expected(): { top: number; edge: number };
            __actual(): { top: number; left: number; right: number };
          };
          return { expected: w.__expected(), actual: w.__actual() };
        });
        expect(Math.abs(actual.top - expected.top)).toBeLessThanOrEqual(1);
        expect(Math.abs((side === "left" ? actual.left : actual.right) - expected.edge)).toBeLessThanOrEqual(1);
      };

      for (const side of ["left", "right"] as const) {
        test(`${side} edge: a prompt's card, then a reply's in the same card, sits where its height puts it`, async () => {
          const page = await open();
          try {
            await card(page, { side, prompt: PROMPT, reply: REPLY, center: 300, x: 52 });
            await placed(page, side);
            const promptHeight = await page.evaluate(
              () => document.querySelector<HTMLElement>(".acpmux-minimap__card")!.offsetHeight,
            );
            // The same component, now a reply's card (no prompt): its reply loses the prompt card's
            // budget, so its height changes; it is placed by the height it has now.
            await card(page, { side, reply: REPLY, center: 300, x: 52 });
            const replyHeight = await page.evaluate(
              () => document.querySelector<HTMLElement>(".acpmux-minimap__card")!.offsetHeight,
            );
            expect(replyHeight).not.toBe(promptHeight);
            await placed(page, side);
          } finally {
            await page.close();
          }
        });

        test(`${side} edge: a reply's card whose content grows is placed again`, async () => {
          const page = await open();
          try {
            await card(page, { side, reply: "One short line.", center: 300, x: 52 });
            await placed(page, side);
            const before = await page.evaluate(
              () => document.querySelector<HTMLElement>(".acpmux-minimap__card")!.offsetHeight,
            );
            // Content that grows without a render (a font or an image loading, a wrap): the card's
            // ResizeObserver places it again.
            await page.evaluate(async () => {
              const reply = document.querySelector<HTMLElement>(".acpmux-minimap__reply")!;
              reply.style.paddingBottom = "60px";
              await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
            });
            const after = await page.evaluate(
              () => document.querySelector<HTMLElement>(".acpmux-minimap__card")!.offsetHeight,
            );
            expect(after).toBeGreaterThan(before);
            await placed(page, side);
          } finally {
            await page.close();
          }
        });
      }
    });
});
