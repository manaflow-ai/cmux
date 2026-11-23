// cmux-web-test-timeout: 300
// New Tab and agent chat use one composer layout even when an old preference is stored.
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
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "idle" } });
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
  /** The template switch radios. */
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

  for (const saved of [null, "claude", "codex", "retired-look"]) {
    test(`New Tab keeps Claude without look dots for stored preference ${saved}`, async () => {
      const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
      await context.addInitScript((look) => {
        if (look) localStorage.setItem("cmux.composer.look", look);
      }, saved);
      const page = await context.newPage();
      try {
        await open(page, "agent-pane.new-tab", "minimal-default");
        expect(await dots(page, ".nt-style")).toEqual([]);
        expect(await page.$(".nt-composer[data-composer-look]")).toBeNull();
        expect(await page.$(".nt-composer .nt-foot .acpmux-model")).not.toBeNull();
        expect(await page.locator(".nt-create button").count()).toBe(3);
        expect(await page.evaluate(() => localStorage.getItem("cmux.composer.look"))).toBe(saved);
        await page.reload();
        await ready(page);
        expect(await page.$(".nt-style, .nt-composer[data-composer-look]")).toBeNull();
      } finally {
        await context.close();
      }
    });
  }

  test("optional templates keep their style switch and Claude's look with a saved Codex preference", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    await context.addInitScript(() => localStorage.setItem("cmux.composer.look", "codex"));
    const page = await context.newPage();
    try {
      await open(page, "agent-pane.new-tab", "template-classic");
      expect(await page.$(".acpmux-newtab")).not.toBeNull();
      expect(await page.$(".acpmux-newtab[data-composer-look], .nt-look-dots")).toBeNull();
      expect(await page.$(".nt-style input[value=classic]:checked")).not.toBeNull();
      await pickDot(page, ".nt-style", "minimal");
      await page.waitForSelector('.nt-screen[data-template="minimal"]');
      expect(await page.$(".nt-style, .nt-composer[data-composer-look]")).toBeNull();
      // Minimal opened fresh (Cards no longer ships, Leo 2026-11-18): Claude's look, no dots.
      await open(page, "agent-pane.new-tab", "minimal-default");
      expect(await page.$(".nt-composer[data-composer-look], .nt-look-dots, .nt-style")).toBeNull();
      expect(await page.$(".nt-composer .nt-above")).not.toBeNull();
      expect(await page.$(".nt-composer .nt-foot .acpmux-model")).not.toBeNull();
      expect(await page.evaluate(() => localStorage.getItem("cmux.composer.look"))).toBe("codex");
    } finally {
      await context.close();
    }
  });

  test("an existing Codex preference cannot change the chat layout or show a style switch", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    await context.addInitScript(() => localStorage.setItem("cmux.composer.look", "codex"));
    const page = await context.newPage();
    try {
      await open(page, "agent-pane.composer", "idle");
      const composer = page.locator(".acpmux-composer");
      const footer = composer.locator(":scope > .acpmux-composer-foot");
      await footer.hover();
      expect(await composer.getAttribute("data-composer-look")).toBeNull();
      expect(await composer.locator(".acpmux-look-dots").count()).toBe(0);
      await page.reload();
      await ready(page);
      expect(await footer.count()).toBe(1);
      expect(await composer.getAttribute("data-composer-look")).toBeNull();
      expect(await page.evaluate(() => localStorage.getItem("cmux.composer.look"))).toBe("codex");
    } finally {
      await context.close();
    }
  });

  test("a long Codex draft keeps the box's controls and the quiet row in a short chat pane", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 400 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer-look", "codex-chat");
    await page.waitForSelector('.acpmux-composer[data-composer-look="codex"]');
    await page
      .locator('.acpmux-composer [contenteditable="true"]')
      .first()
      .fill(Array.from({ length: 20 }, (_, i) => `Long draft line ${i + 1} in a short pane.`).join("\n"));
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const bounds = await page.$eval(".acpmux-main", (main) => {
      const footer = main.querySelector(".acpmux-composer-foot")!.getBoundingClientRect();
      const box = main.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      const pane = main.getBoundingClientRect();
      return { footerBottom: footer.bottom, boxTop: box.top, paneBottom: pane.bottom };
    });
    expect(bounds.footerBottom).toBeLessThanOrEqual(bounds.paneBottom);
    expect(bounds.boxTop).toBeGreaterThanOrEqual(44);
    await context.close();
  });

  test("a long Codex shell draft keeps its field clear of actions in a short pane", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 400 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer-look", "codex-chat");
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("!");
    const shell = page.locator(".acpmux-shell-field");
    await shell.waitFor();
    await shell.fill(Array.from({ length: 20 }, (_, i) => `shell line ${i + 1}`).join("\n"));
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const bounds = await page.$eval(".acpmux-composer", (composer) => {
      const field = composer.querySelector(".acpmux-shell-field")!.getBoundingClientRect();
      const actions = composer.querySelector(".acpmux-composer-actions")!.getBoundingClientRect();
      const footer = composer.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      return {
        fieldBottom: field.bottom,
        fieldRight:
          field.right -
          Number.parseFloat(getComputedStyle(composer.querySelector(".acpmux-shell-field")!).paddingRight),
        actionsTop: actions.top,
        actionsLeft: actions.left,
        footerBottom: footer.bottom,
      };
    });
    // The actions stand right of the field (Claude's grid): they never overlap it.
    expect(bounds.fieldRight <= bounds.actionsLeft || bounds.fieldBottom <= bounds.actionsTop).toBe(true);
    expect(bounds.footerBottom).toBeLessThanOrEqual(400);
    await context.close();
  });
});
