// A long report from a background review, the scenario Leo pointed at on ChatGPT (2026-11-02: "see
// this is the kinda scenario we wanna be able to display super nicely"): gallery entry
// agent-pane.long-report. Each variant mounts with its rows, and the report's prose, links and code
// chips are measured so the numbers behind a fix are on record (CMUX_LONG_REPORT_LOG=1 prints them).
//
// CMUX_LONG_REPORT_ARTIFACT_DIR=DIR (or fast-checks' FAST_CHECKS_OUT) also writes 2x stills of every
// variant in light and dark: the lead chat narrow, the report wide.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("long-report-still.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.long-report";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const VARIANTS = [
    { variant: "lead-running", width: 400 },
    { variant: "lead-finished", width: 400 },
    { variant: "report", width: 900 },
    { variant: "report-15px", width: 900 },
  ];
  const LOG = process.env.CMUX_LONG_REPORT_LOG === "1";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("long report", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "report" }, timeoutMs: 200_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width: number, theme: string): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width, height: 1100 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, theme, reducedMotion: "true" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** The last reply's prose: its size, measure and spacing, and how its links and code draw. */
  const measure = (page: Page) =>
    page.evaluate(() => {
      const replies = [...document.querySelectorAll<HTMLElement>(".acpmux-row.acpmux-assistant")];
      const reply = replies.at(-1);
      if (!reply) return null;
      const paragraphs = [...reply.querySelectorAll<HTMLElement>("p")];
      const first = paragraphs[0];
      const style = first ? getComputedStyle(first) : undefined;
      const gaps = paragraphs
        .slice(1)
        .map((p, i) => Math.round(p.getBoundingClientRect().top - paragraphs[i]!.getBoundingClientRect().bottom));
      const link = reply.querySelector<HTMLElement>("a");
      const code = reply.querySelector<HTMLElement>("code");
      const strong = reply.querySelector<HTMLElement>("strong");
      const pick = (element: HTMLElement | null | undefined, keys: string[]) => {
        if (!element) return null;
        const computed = getComputedStyle(element);
        return Object.fromEntries(keys.map((key) => [key, computed.getPropertyValue(key)]));
      };
      return {
        replies: replies.length,
        paragraphs: paragraphs.length,
        fontSize: style?.fontSize,
        lineHeight: style?.lineHeight,
        measure: first ? Math.round(first.getBoundingClientRect().width) : 0,
        gaps,
        links: reply.querySelectorAll("a").length,
        linkIcons: reply.querySelectorAll("a svg, a img").length,
        link: pick(link, ["color", "text-decoration-line", "font-weight"]),
        linkText: link?.textContent,
        code: pick(code, ["font-size", "padding", "border-radius", "background-color"]),
        strong: pick(strong, ["font-weight", "color"]),
      };
    });

  const artifacts = process.env.CMUX_LONG_REPORT_ARTIFACT_DIR ?? process.env.FAST_CHECKS_OUT;

  for (const theme of THEMES)
    for (const { variant, width } of VARIANTS)
      test(`${variant} mounts its report rows (${theme.file})`, async () => {
        const page = await open(variant, width, theme.name);
        try {
          const measured = await measure(page);
          if (LOG) console.log(`LONG_REPORT ${variant} ${theme.file} ${JSON.stringify(measured)}`);
          expect(measured?.replies ?? 0).toBeGreaterThan(0);
          if (variant.startsWith("report")) {
            expect(measured!.paragraphs).toBeGreaterThanOrEqual(8);
            expect(measured!.linkIcons).toBeGreaterThan(0);
          }
          if (artifacts) {
            await mkdir(artifacts, { recursive: true });
            await page.screenshot({
              path: path.join(artifacts, `long-report-${variant}-${theme.file}.png`),
              fullPage: true,
            });
          }
        } finally {
          await page.close();
        }
      });
});
