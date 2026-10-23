// cmux-web-test-timeout: 300
// The composer's two looks (composerLook.ts; Leo 2026-10-22: "first dot claude, second dot codex.
// since it's just all looks anyways. first 2 dots minimal on the new tab page"):
//
// - The New Tab page shows two dots under it, Claude then Codex, Claude checked by default. The
//   second dot gives the page's composer Codex's look (data-composer-look="codex"): the model sits in
//   the box's own row, no quiet row under it. The pick is remembered across a reload.
// - On another page style (Classic) the look dots switch the look only: the page keeps its style,
//   whose own dot (Minimal among them) stays marked, and draws the look; Cards draws Codex's tray.
//
// Real Chromium on the gallery stage. CI fails the file when it cannot launch it
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-look-dots.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-look-dots.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer look dots", () => test("browser", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  const stageURL = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, width })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "minimal-default" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const ready = async (page: Page) => {
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.mouse.move(1, 1);
  };
  const open = async (page: Page, entry: string, variant: string) => {
    await page.goto(stageURL(entry, variant, 760));
    await ready(page);
  };
  /** The look dots' radios: their values, names and which is checked. */
  const dots = (page: Page, scope: string) =>
    page.$$eval(`${scope} input[type=radio]`, (radios) =>
      radios.map((radio) => ({
        value: (radio as HTMLInputElement).value,
        name: radio.getAttribute("aria-label"),
        checked: (radio as HTMLInputElement).checked,
      })),
    );
  const pickDot = async (page: Page, scope: string, value: string) => {
    const box = (await page.$(`${scope} .nt-style-option[data-style="${value}"]`))!;
    await box.hover();
    await box.click();
  };

  test("New Tab: two dots, Claude by default; Codex's dot gives the composer Codex's look and stays", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.new-tab", "minimal-default");
    expect(await dots(page, ".nt-style")).toEqual([
      { value: "claude", name: "Claude", checked: true },
      { value: "codex", name: "Codex", checked: false },
    ]);
    expect(await page.$(".nt-composer[data-composer-look]")).toBeNull();

    await pickDot(page, ".nt-style", "codex");
    await page.waitForSelector('.nt-composer[data-composer-look="codex"]');
    // Codex's look: the model in the box's row, no quiet row under the box.
    expect(await page.$(".nt-composer .nt-box .acpmux-model")).not.toBeNull();
    expect(await page.$(".nt-composer .acpmux-composer-foot")).toBeNull();
    // Still the Minimal page: the look dot does not change the page's style.
    expect(await page.$(".nt-screen[data-template='minimal'], .nt-screen:not([data-template])")).not.toBeNull();

    // The choice is remembered: the page opens on Codex's look again.
    await page.reload();
    await ready(page);
    await page.waitForSelector('.nt-composer[data-composer-look="codex"]');
    expect((await dots(page, ".nt-style")).find((dot) => dot.checked)?.value).toBe("codex");
    await context.close();
  });

  test("on another page style the look dots switch the look only, and Classic and Cards draw it", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.new-tab", "template-classic");
    expect(await page.$(".nt-style input[value=classic]:checked")).not.toBeNull();
    expect(await page.$(".acpmux-newtab[data-composer-look]")).toBeNull();

    // Codex's dot on Classic: the page stays Classic, its box takes Codex's look.
    await pickDot(page, ".nt-style", "codex");
    await page.waitForSelector('.acpmux-newtab[data-composer-look="codex"]');
    expect(await page.$(".nt-screen")).toBeNull();
    // The looks, then the page's styles (Minimal among them), each marking its own pick.
    expect(await dots(page, ".nt-look-dots")).toEqual([
      { value: "claude", name: "Claude", checked: false },
      { value: "codex", name: "Codex", checked: true },
    ]);
    expect(await page.$(".nt-style:not(.nt-look-dots) input[value=classic]:checked")).not.toBeNull();
    expect(await page.$(".nt-style:not(.nt-look-dots) input[value=minimal]")).not.toBeNull();

    // The saved look holds when Classic opens again, and on Cards: the strip is Codex's tray over
    // the box, the model in the box's row, not Cards' pill.
    await page.reload();
    await ready(page);
    await page.waitForSelector('.acpmux-newtab[data-composer-look="codex"]');
    await open(page, "agent-pane.new-tab", "template-cards");
    await page.waitForSelector('.nt-composer[data-composer-look="codex"] > .nt-above');
    expect(await page.$(".nt-composer .nt-toolbar")).toBeNull();
    expect(await page.$(".nt-composer .nt-box .acpmux-model")).not.toBeNull();
    await context.close();
  });
});
