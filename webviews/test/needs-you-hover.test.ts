// Exercise the real Needs You gallery and its stylesheet cascade.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Locator, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("needs-you-hover.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.needs-you", { browser, params: { variant: "list" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const styles = (element: Locator) =>
    element.evaluate((node) => {
      const style = getComputedStyle(node);
      return { background: style.backgroundColor, color: style.color };
    });

  // Optional fleet capture output uses the same fixture and pointer targets as the regression.
  // A supplied base stylesheet lets a capture compare the original cascade without changing HEAD.
  const baseCSS = process.env.CMUX_NEEDS_YOU_HOVER_BASE_CSS;
  const capture = async (page: Page, theme: string, state: string, row: Locator) => {
    if (process.env.CMUX_NEEDS_YOU_HOVER_CAPTURE !== "1") return;
    const metadata = await row.evaluate((node) => {
      const elements = [node, ...node.querySelectorAll(".acpmux-needs-you-ask-about, .acpmux-needs-you-go")];
      return elements.map((element) => {
        const rect = element.getBoundingClientRect();
        return {
          selector: element.className,
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          background: getComputedStyle(element).backgroundColor,
          hovered: element.matches(":hover"),
          active: element.matches(":active"),
        };
      });
    });
    const png = await page.locator(".acpmux-needs-you").screenshot();
    console.log(
      "NEEDS_YOU_HOVER_CAPTURE=" +
        JSON.stringify({
          mode: baseCSS ? "before" : "after",
          theme,
          state,
          viewport: page.viewportSize(),
          metadata,
          png: png.toString("base64"),
        }),
    );
  };

  for (const theme of ["Apple System Colors Light", "Apple System Colors"]) {
    test(`${theme}: only the hovered Needs You control highlights`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
      try {
        const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
        await page.goto(`${base}${galleryFrame("agent-pane.needs-you", { variant: "list", theme })}`);
        if (baseCSS) {
          // Restore the base hit ownership too: its transparent age label blocked Go to source.
          await page.addStyleTag({
            content: `${readFileSync(baseCSS, "utf8")}\n.acpmux-needs-you-age { pointer-events: auto; }`,
          });
        }
        const row = page.locator(".acpmux-needs-you-item").first();
        const askAbout = row.locator(".acpmux-needs-you-ask-about");
        await askAbout.waitFor();
        await page.mouse.move(0, 0);
        const rowRest = await styles(row);
        const go = row.locator(".acpmux-needs-you-go");
        const askRest = await styles(askAbout);
        const goRest = await styles(go);

        await row.locator(".acpmux-needs-you-ask").hover();
        if (baseCSS) expect((await styles(row)).background).not.toBe(rowRest.background);
        else expect(await styles(row)).toEqual(rowRest);
        expect(await styles(askAbout)).toEqual(askRest);
        expect(await styles(go)).toEqual(goRest);
        await capture(page, theme, "row", row);

        for (const [name, button, rest] of [
          ["ask-about", askAbout, askRest],
          ["go-to-source", go, goRest],
        ] as const) {
          // Re-enter the row before its tools: after pointer exit the age occupies their slot.
          await row.locator(".acpmux-needs-you-ask").hover();
          await button.hover();
          expect(
            await button.evaluate((node) => {
              const rect = node.getBoundingClientRect();
              return node.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2));
            }),
          ).toBe(true);
          if (baseCSS) expect((await styles(row)).background).not.toBe(rowRest.background);
          else expect(await styles(row)).toEqual(rowRest);
          expect((await styles(button)).background).not.toBe(rest.background);
          expect((await styles(button)).color).not.toBe(rest.color);
          await capture(page, theme, name, row);
          await page.mouse.down();
          expect((await styles(button)).background).not.toBe(rest.background);
          expect(await button.evaluate((node) => node.matches(":active"))).toBe(true);
          if (!baseCSS) expect(await styles(row)).toEqual(rowRest);
          await capture(page, theme, `${name}-pressed`, row);
          // Release off the button to avoid answering or navigating while checking pressed style.
          await page.mouse.move(0, 0);
          await page.mouse.up();
        }

        await page.mouse.move(0, 0);
        expect(await styles(row)).toEqual(rowRest);
        expect(await styles(askAbout)).toEqual(askRest);
        expect(await styles(go)).toEqual(goRest);
        await row.evaluate((node) => node.setAttribute("data-focused", ""));
        const focused = await styles(row);
        expect(focused.background).not.toBe(rowRest.background);
        await row.locator(".acpmux-needs-you-ask").hover();
        expect(await styles(row)).toEqual(focused);
        await capture(page, theme, "focused-row", row);
      } finally {
        await page.close();
      }
    });
  }
});
