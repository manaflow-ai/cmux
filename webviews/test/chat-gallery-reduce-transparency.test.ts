// The chat's gallery (GalleryDialog.tsx) blurs the pane behind it. Under Reduce Transparency, the
// host's data-reduce-transparency or the system's media query, it is a solid page instead, as the
// other blurred acpmux surfaces are. Real Chromium loads summary.css; it cannot emulate
// prefers-reduced-transparency, so the media block's own rules are checked against the dialog.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-gallery-reduce-transparency.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-gallery-reduce-transparency: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat gallery reduce transparency", () => test("chromium", () => {}));
    return;
  }
  const css = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/summary/summary.css"), "utf8");
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function open(): Promise<Page> {
    const page = await browser!.newPage();
    await page.setContent(
      // A translucent window (or a custom surface) sends a fully clear page background, so the solid
      // look must come from the always-opaque surface token, as the composer's does.
      `<style>:root{--agent-page-bg:transparent;--cmux-surface-solid:rgb(30, 30, 30);--acpmux-base:rgb(40, 40, 40)}${css}</style><div class="acpmux-chat-gallery" id="g"></div>`,
    );
    return page;
  }
  const look = (page: Page) =>
    page.evaluate(() => {
      const style = getComputedStyle(document.getElementById("g")!);
      return { filter: style.backdropFilter, background: style.backgroundColor };
    });

  test("the gallery blurs by default", async () => {
    const page = await open();
    expect((await look(page)).filter).toContain("blur");
    await page.close();
  });

  test("with the host's Reduce Transparency the gallery is solid and unblurred", async () => {
    const page = await open();
    await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
    expect(await look(page)).toEqual({ filter: "none", background: "rgb(30, 30, 30)" });
    await page.close();
  });

  test("the system's Reduce Transparency media block makes the gallery solid and unblurred", async () => {
    const page = await open();
    const set = await page.evaluate(() => {
      const dialog = document.getElementById("g")!;
      const values: Record<string, string> = {};
      for (const sheet of document.styleSheets)
        for (const rule of sheet.cssRules)
          if (rule instanceof CSSMediaRule && rule.conditionText.includes("prefers-reduced-transparency"))
            for (const inner of rule.cssRules)
              if (inner instanceof CSSStyleRule && dialog.matches(inner.selectorText)) {
                for (const name of ["backdrop-filter", "background", "background-color"]) {
                  const value = inner.style.getPropertyValue(name);
                  if (value) values[name] = value;
                }
              }
      return values;
    });
    expect(set["backdrop-filter"]).toBe("none");
    expect(set.background ?? set["background-color"]).toBe("var(--cmux-surface-solid, var(--acpmux-base, Canvas))");
    await page.close();
  });
});
