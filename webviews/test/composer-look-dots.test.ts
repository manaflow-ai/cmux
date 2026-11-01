// cmux-web-test-timeout: 300
// The composer's two looks (composerLook.ts; Leo 2026-10-22: "first dot claude, second dot codex.
// since it's just all looks anyways. first 2 dots minimal on the new tab page, and then when you're
// in a chat you can also switch the dots if you hover on that bottom area"):
//
// - The New Tab page shows three dots under it (Leo 2026-10-23: "1 CLAUDE MINIMAL / 2 CLAUDE MINIMAL
//   + NEW TAB/TERMINAL/WHATEVER / 3 CODEX MINIMAL"; newtab/tabDots.ts): Claude Minimal checked by
//   default; the second adds the quick action pills under Claude's composer; the third gives the
//   composer Codex's look (data-composer-look="codex"): Claude's button layout, the mode and model in
//   the quiet row under the box (Leo 2026-11-01: "we already have a good version"), Codex's tray over
//   it, and no pills. Arrow keys move across the three. The pick is remembered
//   across a reload.
// - On another page style (Classic) the dots switch the look only: the page keeps its style, whose
//   own dot (Minimal among them) stays marked, and draws the look; Cards draws Codex's tray.
// - In a chat the same two dots sit in the composer's bottom area, unseen until the pointer is over
//   that area. The second dot switches the chat composer's look: the form takes
//   data-composer-look="codex", every control stays where it was (the mode and model in the quiet
//   row, the dots over its middle), and the first dot brings Claude's look back.
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
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "quiet-chips" } });
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
  /** Whether the dots draw: the group's opacity once its fade has run. */
  const shown = (page: Page, scope: string) =>
    page.$eval(`${scope} .acpmux-look-dots`, (group) => {
      for (const animation of group.getAnimations()) animation.finish();
      return Number(getComputedStyle(group).opacity) > 0.5;
    });
  const pickDot = async (page: Page, scope: string, value: string) => {
    const box = (await page.$(`${scope} .nt-style-option[data-style="${value}"]`))!;
    await box.hover();
    await box.click();
  };

  test("New Tab: three dots, Claude Minimal by default; the second adds the pills, the third is Codex's look", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.new-tab", "minimal-default");
    expect(await dots(page, ".nt-style")).toEqual([
      { value: "claude", name: "Claude Minimal", checked: true },
      { value: "claudeActions", name: "Claude Minimal + Quick Actions", checked: false },
      { value: "codex", name: "Codex Minimal", checked: false },
    ]);
    expect(await page.$(".nt-composer[data-composer-look]")).toBeNull();
    expect(await page.$(".nt-composer .nt-box .acpmux-model")).toBeNull();
    expect(await page.$(".nt-composer .acpmux-composer-foot .acpmux-model")).not.toBeNull();
    expect(await page.$(".nt-create")).toBeNull();

    // The second dot: Claude's composer with New terminal, New browser tab and New chat under it.
    await pickDot(page, ".nt-style", "claudeActions");
    await page.waitForSelector(".nt-create [data-create=chat]");
    expect(await page.$(".nt-composer[data-composer-look]")).toBeNull();
    expect(await page.$(".nt-stage")).toBeNull();

    await pickDot(page, ".nt-style", "codex");
    await page.waitForSelector('.nt-composer[data-composer-look="codex"]');
    // Codex's look lays the buttons out as Claude's: the mode and model in the quiet row under the box.
    expect(await page.$(".nt-composer .nt-box .acpmux-model")).toBeNull();
    expect(await page.$(".nt-composer .acpmux-composer-foot .acpmux-model")).not.toBeNull();
    await page.waitForFunction(() => !document.querySelector(".nt-create"));
    // Still the Minimal page: the look dot does not change the page's style.
    expect(await page.$(".nt-screen[data-template='minimal'], .nt-screen:not([data-template])")).not.toBeNull();

    // The choice is remembered: the page opens on Codex's look again.
    await page.reload();
    await ready(page);
    await page.waitForSelector('.nt-composer[data-composer-look="codex"]');
    expect((await dots(page, ".nt-style")).find((dot) => dot.checked)?.value).toBe("codex");
    await context.close();
  });

  test("New Tab: arrow keys move across the three dots, each setting the look and the pills", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.new-tab", "minimal-default");
    const checked = async () => (await dots(page, ".nt-look-dots")).find((dot) => dot.checked)?.value;
    const state = () =>
      page.evaluate(() => ({
        codex: !!document.querySelector('.nt-composer[data-composer-look="codex"]'),
        pills: !!document.querySelector(".nt-create"),
      }));
    await page.focus(".nt-look-dots input[value=claude]");
    await page.keyboard.press("ArrowRight");
    await page.waitForSelector(".nt-create");
    expect(await checked()).toBe("claudeActions");
    expect(await state()).toEqual({ codex: false, pills: true });
    await page.keyboard.press("ArrowRight");
    await page.waitForSelector('.nt-composer[data-composer-look="codex"]');
    await page.waitForFunction(() => !document.querySelector(".nt-create"));
    expect(await checked()).toBe("codex");
    expect(await state()).toEqual({ codex: true, pills: false });
    await page.keyboard.press("ArrowLeft");
    await page.waitForSelector(".nt-create");
    expect(await checked()).toBe("claudeActions");
    expect(await state()).toEqual({ codex: false, pills: true });
    await page.keyboard.press("ArrowLeft");
    await page.waitForFunction(() => !document.querySelector(".nt-create"));
    expect(await checked()).toBe("claude");
    expect(await state()).toEqual({ codex: false, pills: false });
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
    // The three dots, then the page's styles (Minimal among them), each marking its own pick.
    expect(await dots(page, ".nt-look-dots")).toEqual([
      { value: "claude", name: "Claude Minimal", checked: false },
      { value: "claudeActions", name: "Claude Minimal + Quick Actions", checked: false },
      { value: "codex", name: "Codex Minimal", checked: true },
    ]);
    expect(await page.$(".nt-style:not(.nt-look-dots) input[value=classic]:checked")).not.toBeNull();
    expect(await page.$(".nt-style:not(.nt-look-dots) input[value=minimal]")).not.toBeNull();

    // The saved look holds when Classic opens again, and on Cards: the strip is Codex's tray over
    // the box, the model in the quiet row under it, not Cards' pill.
    await page.reload();
    await ready(page);
    await page.waitForSelector('.acpmux-newtab[data-composer-look="codex"]');
    await open(page, "agent-pane.new-tab", "template-cards");
    await page.waitForSelector('.nt-composer[data-composer-look="codex"] .acpmux-composer-foot .acpmux-model');
    expect(await page.$(".nt-composer .nt-above")).not.toBeNull();
    expect(await page.$(".nt-composer .nt-toolbar")).toBeNull();
    expect(await page.$(".nt-composer .nt-box .acpmux-model")).toBeNull();
    await context.close();
  });

  test("in a chat the dots show on hover in the composer's bottom area and switch its look", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer", "quiet-chips");
    const form = ".acpmux-composer";
    // Claude's look: the quiet row under the box holds the dots, unseen at rest.
    expect(await page.$(`${form}[data-composer-look]`)).toBeNull();
    // The dots sit over the quiet row, inside its height.
    const row = (await (await page.$(`${form} .acpmux-composer-foot`))!.boundingBox())!;
    const group = (await (await page.$(`${form} .acpmux-look-dots`))!.boundingBox())!;
    expect(group.y >= row.y && group.y + group.height <= row.y + row.height).toBe(true);
    expect(await shown(page, form)).toBe(false);
    expect(await dots(page, `${form} .acpmux-look-dots`)).toEqual([
      { value: "claude", name: "Claude", checked: true },
      { value: "codex", name: "Codex", checked: false },
    ]);

    // The pointer in the bottom area's empty room, clear of the controls: the dots show.
    const foot = (await (await page.$(`${form} .acpmux-composer-foot`))!.boundingBox())!;
    await page.mouse.move(foot.x + foot.width * 0.35, foot.y + foot.height / 2);
    expect(await shown(page, form)).toBe(true);

    await pickDot(page, form, "codex");
    await page.waitForSelector(`${form}[data-composer-look="codex"]`);
    // Codex's look lays the buttons out as Claude's: the mode and model stay in the quiet row, the
    // dots over its middle, shown on hover there; the first dot goes back.
    expect(await page.$(`${form} .acpmux-composer-box .acpmux-model`)).toBeNull();
    expect(await page.$(`${form} .acpmux-composer-foot .acpmux-model`)).not.toBeNull();
    expect(await page.$(`${form} .acpmux-composer-foot .acpmux-access`)).not.toBeNull();
    await page.mouse.move(1, 1);
    expect(await shown(page, form)).toBe(false);
    const codexRow = (await (await page.$(`${form} .acpmux-composer-foot`))!.boundingBox())!;
    const codexDots = (await (await page.$(`${form} .acpmux-look-dots`))!.boundingBox())!;
    expect(codexDots.y >= codexRow.y && codexDots.y + codexDots.height <= codexRow.y + codexRow.height).toBe(true);
    await page.mouse.move(codexDots.x + codexDots.width / 2, codexDots.y + codexDots.height / 2);
    expect(await shown(page, form)).toBe(true);
    await pickDot(page, form, "claude");
    await page.waitForFunction((selector) => !document.querySelector(`${selector}[data-composer-look]`), form);
    expect(await page.$(`${form} .acpmux-composer-foot`)).not.toBeNull();
    await context.close();
  });

  test("a long Codex draft keeps the box's controls and the quiet row in a short chat pane", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 400 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer", "quiet-chips");
    await pickDot(page, ".acpmux-composer", "codex");
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
    await open(page, "agent-pane.composer", "quiet-chips");
    await pickDot(page, ".acpmux-composer", "codex");
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

  test("in a chat the dots switch the look by keys both ways, and Escape goes back to the prompt", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer", "quiet-chips");
    const form = ".acpmux-composer";
    /** The focused element: a look dot's value, or what else has the keyboard. */
    const focused = () =>
      page.evaluate(() => {
        const active = document.activeElement as HTMLElement | null;
        if (active?.matches(".acpmux-look-dots input[type=radio]")) return `dot:${(active as HTMLInputElement).value}`;
        if (active?.closest(".acpmux-composer-box") && active.matches("[contenteditable], textarea")) return "prompt";
        return active?.tagName ?? "none";
      });
    const settle = () =>
      page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

    await page.focus(`${form} .acpmux-look-dots input[value=claude]`);
    expect(await focused()).toBe("dot:claude");
    expect(await shown(page, form)).toBe(true);

    // ArrowRight: Codex's look, the keyboard still on its dot, the dots still drawn.
    await page.keyboard.press("ArrowRight");
    await page.waitForSelector(`${form}[data-composer-look="codex"]`);
    await settle();
    expect(await focused()).toBe("dot:codex");
    expect(await shown(page, form)).toBe(true);

    // ArrowLeft: back to Claude's look, the keyboard on the first dot.
    await page.keyboard.press("ArrowLeft");
    await page.waitForFunction((selector) => !document.querySelector(`${selector}[data-composer-look]`), form);
    await settle();
    expect(await focused()).toBe("dot:claude");
    expect(await shown(page, form)).toBe(true);

    // Escape: back to the prompt.
    await page.keyboard.press("Escape");
    await settle();
    expect(await focused()).toBe("prompt");
    await context.close();
  });

  test("in shell mode Escape on a look dot goes back to the shell prompt", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer", "quiet-chips");
    const form = ".acpmux-composer";
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("!");
    await page.locator(".acpmux-shell-field").waitFor();

    await page.focus(`${form} .acpmux-look-dots input[value=claude]`);
    await page.keyboard.press("Escape");
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    expect(await page.evaluate(() => document.activeElement?.className ?? "none")).toBe("acpmux-shell-field");
    await context.close();
  });

  test("arrow keys keep the keyboard on the dots right after load and right after a click", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 600 } });
    const page = await context.newPage();
    await open(page, "agent-pane.composer", "quiet-chips");
    const form = ".acpmux-composer";
    const focused = () =>
      page.evaluate(() => {
        const active = document.activeElement as HTMLInputElement | null;
        return active?.matches(".acpmux-look-dots input[type=radio]")
          ? `dot:${active.value}`
          : (active?.tagName ?? "none");
      });
    const look = () => page.$eval(form, (element) => (element as HTMLElement).dataset.composerLook ?? "claude");
    const settle = () =>
      page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

    // The page's clock as at a fresh load (performance.now() near 0): keys are keys from the start.
    await page.evaluate(() => {
      const real = performance.now.bind(performance);
      const origin = real();
      performance.now = () => real() - origin;
    });
    await page.focus(`${form} .acpmux-look-dots input[value=claude]`);
    await page.keyboard.press("ArrowRight");
    await settle();
    expect(await look()).toBe("codex");
    expect(await focused()).toBe("dot:codex");
    await page.keyboard.press("ArrowRight");
    await settle();
    expect(await look()).toBe("claude");
    expect(await focused()).toBe("dot:claude");

    // A click on the marked dot, then a key at once: the key's pick is a key's, the keyboard stays.
    const marked = (await page.$(`${form} .nt-style-option[data-style="claude"]`))!;
    await marked.hover();
    await marked.click();
    await page.keyboard.press("ArrowRight");
    await settle();
    expect(await look()).toBe("codex");
    expect(await focused()).toBe("dot:codex");
    await context.close();
  });
});
