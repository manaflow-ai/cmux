// l10n-allow-file: geometry diagnostics.
// Every transcript meta row (a tool row, a sent message, a received message, an inbox notice, a
// background task, a sub-session card) puts its icon in one column and its words in one column:
// each icon's left edge and each label's first glyph within 0.5px of the others (Leo, 2026-10-31,
// on a sent row over an inbox row: "WHY IS THIS ONCE AGAIN FUCKING MISALIGNED" / "YOU GUYS CANNOT
// FUCKIGN MISALIGN THINGS"). Real components (test/browser/transcript-meta-columns.harness.tsx).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-meta-columns-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  /// Each row kind's icon slot and the element whose first text is its label.
  const ROWS: Record<string, [icon: string, label: string]> = {
    tool: [".cv-tool__icon", ".cv-tool__text"],
    sent: [".cv-agentmsg__icon", ".cv-agentmsg__words"],
    received: [".cv-received__mark", ".cv-received__from"],
    inbox: [".cv-received__mark", ".cv-received__from"],
    "background-task": [".cv-tool__icon", ".cv-tool__text"],
    subsession: [".cv-disclosure__icon", ".cv-disclosure__label"],
  };
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-meta-columns.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const theme of ["dark", "light"] as const)
    test(`${theme}: every meta row shares one icon column and one text column`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 600 }, deviceScaleFactor: 2 });
      try {
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.message));
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-meta-columns.html?theme=${theme}`);
        await page.locator('[data-meta-row="subsession"] .cv-disclosure__label').waitFor();
        await page.evaluate(() => document.fonts.ready);
        const rows = await page.evaluate((selectors) => {
          /// The left of the first rendered character under `el`, past any padding or margin.
          const textLeft = (el: Element) => {
            const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              if (!node.textContent?.trim()) continue;
              const range = document.createRange();
              const at = node.textContent.search(/\S/);
              range.setStart(node, at);
              range.setEnd(node, at + 1);
              const box = range.getBoundingClientRect();
              if (box.width > 0) return box.left;
            }
            return Number.NaN;
          };
          return Object.entries(selectors).map(([kind, [icon, label]]) => {
            const scope = document.querySelector(`[data-meta-row="${kind}"]`);
            const iconEl = scope?.querySelector(icon);
            const labelEl = scope?.querySelector(label);
            if (!iconEl || !labelEl) return { kind, icon: Number.NaN, iconWidth: Number.NaN, label: Number.NaN };
            const box = iconEl.getBoundingClientRect();
            return { kind, icon: box.left, iconWidth: box.width, label: textLeft(labelEl) };
          });
        }, ROWS);
        console.log(`META_COLUMNS ${JSON.stringify({ theme, rows })}`);
        expect(errors).toEqual([]);
        const [first] = rows;
        const off = rows.flatMap((row) => [
          ...(Number.isFinite(row.icon) && Number.isFinite(row.label) ? [] : [`${row.kind}: not drawn`]),
          ...(Math.abs(row.icon - first!.icon) > 0.5
            ? [`${row.kind} icon at ${row.icon}, tool at ${first!.icon}`]
            : []),
          ...(Math.abs(row.iconWidth - first!.iconWidth) > 0.5
            ? [`${row.kind} icon slot ${row.iconWidth}px, tool ${first!.iconWidth}px`]
            : []),
          ...(Math.abs(row.label - first!.label) > 0.5
            ? [`${row.kind} label at ${row.label}, tool at ${first!.label}`]
            : []),
        ]);
        expect(off).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
