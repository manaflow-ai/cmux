// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
// Session Info's Sources rows hover as its other rows do (sessionInfo.css: "Every row that takes a click
// ... hovers one way"; leo-workspace design/menus.md: a highlight covers only what it belongs to).
// Before, a Sources row lit on hover whether or not it took a click, and its file or link lit as
// well, so the two tints stacked over the link inside a lighter band, and an MCP tool's row, which
// opens nothing, lit like a link. In real Chromium on the gallery's agent-pane.chat-inspector `full`:
// a link's row lights once with the panel's row tint and the link itself adds none; an MCP tool's
// row never lights. With FAST_CHECKS_OUT set it writes 2x light and dark stills of the hovered row.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-sources-hover.test.ts", async () => {
  const ENTRY = "agent-pane.chat-inspector";
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-info-sources-hover: skipping (run `bunx playwright install chromium`)");
    describe.skip("session info sources hover", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser });
    if (out) await mkdir(out, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (colorScheme: "light" | "dark"): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({
      viewport: { width: 420, height: 900 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "full", colorScheme, width: 420, height: 900 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.waitForSelector("a.acpmux-session-info-source__link");
    return page;
  };

  /** The hovered source row's background and its link's, and the panel's row tint. */
  const backgrounds = (page: Page, label: string) =>
    page.evaluate((text) => {
      const row = [...document.querySelectorAll<HTMLElement>(".acpmux-session-info-source")].find(
        (candidate) => candidate.textContent?.trim() === text,
      )!;
      const link = row.querySelector<HTMLElement>(".acpmux-session-info-source__link");
      const probe = document.createElement("div");
      probe.style.background = "var(--acpmux-session-info-row-hover)";
      row.append(probe);
      const tint = getComputedStyle(probe).backgroundColor;
      probe.remove();
      return {
        row: getComputedStyle(row).backgroundColor,
        link: link ? getComputedStyle(link).backgroundColor : null,
        tint,
      };
    }, label);
  const clear = "rgba(0, 0, 0, 0)";

  for (const colorScheme of ["light", "dark"] as const) {
    test(`a link's row lights once; an MCP tool's row never lights (${colorScheme})`, async () => {
      const page = await open(colorScheme);
      try {
        const url = "cmux.com/docs/session-info";
        await page.hover(`.acpmux-session-info-source a.acpmux-session-info-source__link >> text=${url}`);
        // The still first, so a red run still shows what it drew.
        if (out)
          await page.screenshot({ path: path.join(out, `session-info-sources-hover-${colorScheme}-chromium.png`) });
        const link = await backgrounds(page, url);
        expect(link.tint).not.toBe(clear);
        expect({ row: link.row, link: link.link }).toEqual({ row: link.tint, link: clear });

        const mcp = "github · search issues";
        await page.hover(`.acpmux-session-info-source >> text=${mcp}`);
        expect((await backgrounds(page, mcp)).row).toBe(clear);
      } finally {
        await page.close();
      }
    });
  }
});
