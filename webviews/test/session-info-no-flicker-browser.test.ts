// Session Info paints nothing for an update that changes nothing it shows (Leo, 2026-11-03: "i don't
// want to see flickers of the session info or anything when there's random re-renders EVER"). In real
// Chromium, the pane of test/browser/session-info-no-flicker.harness.tsx streams 50 updates (a reply
// token by token, tool calls that produce nothing, the dock's live line, a usage tick) at each of
// Session Info's three places (in the gutter, pushing the chat, over the chat). Over all of them the
// panel takes no DOM mutation, no layout-shift entry names a node inside it, and its box never moves.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-no-flicker-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const UPDATES = 50;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/session-info-no-flicker.html";
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
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // 1400: the panel floats in the chat's gutter; 1000: it pushes the chat; 600: it lies over the chat.
  for (const width of [1400, 1000, 600]) {
    test(`at ${width} px, ${UPDATES} streamed updates paint nothing in Session Info`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width, height: 720 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${PAGE}`);
        await page.locator("button.acpmux-session-info-toggle").waitFor();
        // A narrow pane waits for the toggle (sessionInfoFits).
        const closed = page.locator('button.acpmux-session-info-toggle[aria-pressed="false"]');
        if (await closed.count()) await closed.click();
        await page.waitForFunction(
          () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
        );
        // The first running update draws what a running chat shows (the dock's live line), then the
        // panel's enter settles.
        await page.evaluate(() => window.__step(0));
        // fixed-wait: the panel's enter transition and its first reads settle before the window opens.
        await page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 600)));
        const result = await page.evaluate(async (updates) => {
          const panel = document.querySelector<HTMLElement>("aside.acpmux-session-info")!;
          const box = () => {
            const rect = panel.getBoundingClientRect();
            return [rect.left, rect.top, rect.width, rect.height].map((n) => Math.round(n * 10) / 10).join(",");
          };
          const mutations: string[] = [];
          const observer = new MutationObserver((records) => {
            for (const record of records) {
              const target = record.target as Element;
              const name = target.nodeType === 1 ? `${target.tagName}.${target.getAttribute("class") ?? ""}` : "#text";
              mutations.push(`${record.type}${record.attributeName ? `:${record.attributeName}` : ""} ${name}`);
            }
          });
          observer.observe(panel, { subtree: true, childList: true, attributes: true, characterData: true });
          const shifts: string[] = [];
          const shiftObserver = new PerformanceObserver((list) => {
            for (const entry of list.getEntries() as (PerformanceEntry & {
              value: number;
              sources?: { node?: Node | null }[];
            })[]) {
              for (const source of entry.sources ?? [])
                if (source.node && panel.contains(source.node))
                  shifts.push(`${entry.value.toFixed(4)} ${(source.node as Element).className ?? "#text"}`);
            }
          });
          shiftObserver.observe({ type: "layout-shift" });
          const boxes = new Set<string>([box()]);
          const renders = window.__renders();
          for (let step = 1; step <= updates; step++) {
            window.__step(step);
            boxes.add(box());
            await new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
            boxes.add(box());
          }
          // fixed-wait: the observed window stays open for timers and frames the updates scheduled.
          await new Promise((resolve) => setTimeout(resolve, 300));
          boxes.add(box());
          for (const record of observer.takeRecords()) mutations.push(`${record.type} late`);
          observer.disconnect();
          shiftObserver.disconnect();
          return {
            mutations: [...new Set(mutations)].slice(0, 20),
            mutationCount: mutations.length,
            shifts: shifts.slice(0, 20),
            boxes: [...boxes],
            renders: window.__renders() - renders,
            placement: panel.dataset.placement,
          };
        }, UPDATES);
        console.log(`session-info-no-flicker ${width}px:`, JSON.stringify(result));
        expect(result.mutations).toEqual([]);
        expect(result.shifts).toEqual([]);
        expect(result.boxes).toHaveLength(1);
      } finally {
        await page.close();
      }
    });
  }
});
