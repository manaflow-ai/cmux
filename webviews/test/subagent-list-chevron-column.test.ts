// l10n-allow-file: gallery fixture names are test data.
// An open subagent group's lines (subagents/SubagentGroup.tsx SubagentListRow) in real Chromium
// (Playwright; CI fails the file when it cannot launch, requireBrowserLane). A running line has a
// Stop button; it used to sit at the line's end, after the chevron, so the running line's chevron
// stood 34px left of an ended line's. Leo, 2026-10-31: "and of course align this right side's
// chevrons". Here: every line's chevron ends on one x, and a running line's Stop sits between its
// time and its chevron, on the line's centre.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-list-chevron-column.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.subagents";

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "open" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const width of [760, 420]) {
    test(`a running line's chevron ends on an ended line's x, its Stop before it, at ${width}px`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({ viewport: { width, height: 640 }, reducedMotion: "reduce" });
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "open" })}`);
      await page.waitForFunction(() => document.querySelectorAll("button.cv-subagent").length === 4);
      await page.waitForSelector(".cv-subagent-stoppable .cv-subagent__stop");
      const lines = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLButtonElement>("button.cv-subagent")].map((line) => {
          const rect = (node: Element | null) => {
            if (!node) return null;
            const box = node.getBoundingClientRect();
            return { left: box.left, right: box.right, top: box.top, bottom: box.bottom };
          };
          return {
            row: rect(line)!,
            time: rect(line.querySelector(".cv-subagent__time"))!,
            chevron: rect(line.querySelector(":scope > svg"))!,
            stop: rect(
              line.parentElement?.classList.contains("cv-subagent-stoppable")
                ? line.parentElement.querySelector(":scope > .cv-subagent__stop")
                : null,
            ),
          };
        }),
      );
      expect(lines).toHaveLength(4);
      const stoppable = lines.filter((line) => line.stop);
      expect(stoppable.length).toBeGreaterThan(0);
      expect(stoppable.length).toBeLessThan(lines.length);
      const rights = lines.map((line) => Math.round(line.chevron.right));
      expect(new Set(rights).size).toBe(1);
      for (const line of stoppable) {
        const stop = line.stop!;
        expect(stop.left).toBeGreaterThanOrEqual(line.time.right);
        expect(stop.right).toBeLessThanOrEqual(line.chevron.left);
        const middle = (box: { top: number; bottom: number }) => (box.top + box.bottom) / 2;
        expect(Math.abs(middle(stop) - middle(line.row))).toBeLessThanOrEqual(1);
      }
      await page.close();
    });
  }
});
