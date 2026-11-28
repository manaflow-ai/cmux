// The windowed Plain English list places each file's section at its offset (`position: absolute`,
// PlainEnglishView.tsx). That rule must reach only the windowed list: the gallery's prose variant
// (PlainEnglish.gallery.tsx) draws the same `.plain-english-file` sections in plain flow, with no
// spacer, and a global rule stacked them all at the same top. Each section must start at or below
// the bottom of the one before it. Only a real layout shows it (jsdom has none).
//
// Real Chromium from Playwright. Locally: CMUX_BROWSER_TESTS=1 bun test test/plain-english-prose.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("plain-english-prose.test.ts", async () => {
  if (!(await probeEngineOrSkip("plain-english-prose", "chromium", chromium))) return;
  setDefaultTimeout(120_000);
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
    await warmViteServer(vite, "/test/browser/plain-english-prose.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the prose variant's file sections do not overlap: each starts at or below the one before", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/plain-english-prose.html`);
    await page.waitForFunction(() => window.__proseSections !== undefined);
    const sections = (await page.evaluate(() => window.__proseSections!)) as Array<{ top: number; bottom: number }>;
    await page.close();
    expect(sections.length).toBeGreaterThan(1);
    for (const [index, section] of sections.entries()) {
      expect(section.bottom).toBeGreaterThan(section.top);
      if (index > 0) expect(section.top).toBeGreaterThanOrEqual(sections[index - 1]!.bottom);
    }
  });
});
