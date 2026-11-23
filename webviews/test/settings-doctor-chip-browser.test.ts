// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

// Issue 52838: the Settings sidebar's customization notice ("17 things change your customization:
// app-…") showed only the top half of its second line. The chip's own rules (one class) lost to the
// button's two-class `height: 24px` and control font size, so two lines overflowed a 24px button and
// the sidebar cut them. Measured in real engines: the button grows with its text, the text is the
// detail size, whole lines only (at most three), the dot centered on the first line, and nothing
// below the sidebar's bottom, at each density and text size, light and dark.
await requireBrowserLane("settings-doctor-chip-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const entry = "pages.settings-customize-doctor";
  const variant = "treatment-chip-many";

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, entry, { params: { variant } });
  }, 200_000);
  afterAll(async () => vite?.close());

  async function open(page: Page, colorScheme: "light" | "dark") {
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme, width: 900, height: 640 })}`,
    );
    await page.waitForSelector(".settings[data-page-shown]");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryReady));
    await page.waitForSelector('[data-doctor-notice="chip"] .doctor-line');
  }

  // Page density (rows and controls) and text size, set apart as the app's Density and Text Size do
  // (pages/shared/pageDensity.css; gallery pageDensityFixtures runs ultra-compact to spacious).
  const densities = [24 / 30, 1, 36 / 30];
  const textScales = [0.85, 1, 1.3];

  function measure(page: Page, density: number, text: number) {
    return page.evaluate(
      ([density, text]) => {
        const root = document.documentElement;
        root.style.setProperty("--cmux-density-scale", String(density));
        root.style.setProperty("--cmux-density-text-scale", String(text));
        const sidebar = document.querySelector<HTMLElement>(".sidebar")!;
        const button = document.querySelector<HTMLElement>(".doctor-chip-open")!;
        const line = button.querySelector<HTMLElement>(".doctor-line")!;
        const dot = button.querySelector<HTMLElement>(".doctor-dot")!;
        const probe = document.createElement("span");
        probe.style.fontSize = "var(--text-detail)";
        probe.style.lineHeight = "var(--text-detail--line-height)";
        sidebar.append(probe);
        const detail = getComputedStyle(probe);
        const want = { size: parseFloat(detail.fontSize), lineHeight: parseFloat(detail.lineHeight) };
        probe.remove();
        const style = getComputedStyle(line);
        const s = sidebar.getBoundingClientRect();
        const b = button.getBoundingClientRect();
        const l = line.getBoundingClientRect();
        const d = dot.getBoundingClientRect();
        return {
          want,
          size: parseFloat(style.fontSize),
          lineHeight: parseFloat(style.lineHeight),
          sidebar: { bottom: s.bottom - parseFloat(getComputedStyle(sidebar).paddingBottom) },
          button: { top: b.top, bottom: b.bottom, height: b.height },
          line: { top: l.top, bottom: l.bottom, height: l.height, scroll: line.scrollHeight },
          dotCenter: d.top + d.height / 2,
          dotSize: d.height,
          tooltip: button.title,
          text: line.textContent ?? "",
        };
      },
      [density, text] as const,
    );
  }

  for (const engine of [chromium, webkit]) {
    test(`${engine.name()}: the doctor chip shows whole lines at every density and text size, light and dark`, async () => {
      const browser = await engine.launch({ headless: true, timeout: 30_000 });
      try {
        const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
        for (const colorScheme of ["light", "dark"] as const) {
          await open(page, colorScheme);
          for (const density of densities)
            for (const text of textScales) {
              const m = await measure(page, density, text);
              const at = `${colorScheme} density ${density.toFixed(2)} text ${text}`;
              // Detail size, not the button's control size.
              expect(m.size, at).toBeCloseTo(m.want.size, 1);
              expect(m.lineHeight, at).toBeCloseTo(m.want.lineHeight, 1);
              // Whole lines only: two or three of them (17 long findings), never a half line.
              const lines = m.line.height / m.lineHeight;
              expect(Math.abs(lines - Math.round(lines)), at).toBeLessThan(0.05);
              expect(Math.round(lines), at).toBeGreaterThanOrEqual(2);
              expect(Math.round(lines), at).toBeLessThanOrEqual(3);
              // The button holds its text, and the sidebar holds the button.
              expect(m.line.top, at).toBeGreaterThanOrEqual(m.button.top - 0.5);
              expect(m.line.bottom, at).toBeLessThanOrEqual(m.button.bottom + 0.5);
              expect(m.button.bottom, at).toBeLessThanOrEqual(m.sidebar.bottom + 0.5);
              // The 6px dot is centered on the first line.
              expect(m.dotSize, at).toBeCloseTo(6, 0);
              expect(Math.abs(m.dotCenter - (m.line.top + m.lineHeight / 2)), at).toBeLessThan(1);
              // The full line is the tooltip, and it reads naturally.
              expect(m.tooltip, at).toBe(m.text);
              expect(m.text, at).toStartWith("17 customization problems: ");
            }
        }
      } finally {
        await browser.close();
      }
    }, 120_000);
  }
});
