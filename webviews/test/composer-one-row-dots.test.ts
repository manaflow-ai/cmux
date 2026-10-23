// cmux-web-test-timeout: 300
// Claude's look is one row, and the look dots keep one place (Leo 2026-10-23: "I mean, like the claw
// thing should be one single row, and then the codex and the codex, the dot switches thing, like it
// should just be, like in the same kind of spot, but, like, it's just buried within the codex thing
// when it's there, like at the bottom area"):
//
// - New Tab in Claude's look: nothing over the composer's box; the folder, the computer and the model
//   are one row under it (newtab/screen.css, NewTabScreen.tsx).
// - New Tab with the composer at the page's foot, and a chat: the dots sit at the same place in the
//   pane in both looks, out of the flow on its bottom edge, in the gutter under the composer's last
//   part (Claude's quiet row, Codex's box), never on it and never past the pane's edge. They add no
//   line: the quiet row keeps its few px over the edge (composer-bottom-space.test.ts).
// - A look switched by keys leaves the dots where they were, the keyboard on them, and Escape goes
//   back.
//
// Real Chromium on the gallery stage. CI fails the file when it cannot launch it
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-one-row-dots.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-one-row-dots.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer one row and dots", () => test("browser", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  const ENTRY = "agent-pane.composer-look";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "newtab-stage-claude" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A gallery variant, at 760 px, its pointer parked in the corner. */
  const open = async (variant: string, height = 520) => {
    const context = await browser.newContext({ viewport: { width: 760, height } });
    const page = await context.newPage();
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.mouse.move(1, 1);
    return { page, close: () => context.close() };
  };
  const settle = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  /** Where the dots sit: the gap from the composer's last part's bottom (the quiet row, or the box
   *  with Codex's look) to the dots' top, the room left under them to the pane's edge, and their
   *  place in the pane. */
  const dotsPlace = (page: Page, composer: string, dots: string) =>
    page.evaluate(
      ({ composer, dots }) => {
        const host = document.querySelector(composer)!;
        const last = (host.querySelector(".acpmux-composer-foot") ??
          host.querySelector(".nt-box, .acpmux-composer-box"))!.getBoundingClientRect();
        const pane = document.querySelector(".acpmux-main")!.getBoundingClientRect();
        const group = document.querySelector(dots)!.getBoundingClientRect();
        return {
          gap: group.top - last.bottom,
          under: Math.min(pane.bottom, window.innerHeight) - group.bottom,
          top: Math.round(group.top - pane.top),
          left: Math.round(group.left - pane.left),
        };
      },
      { composer, dots },
    );
  /** The dots in one place in both looks, clear of the composer, inside the pane. */
  const samePlace = (claude: Awaited<ReturnType<typeof dotsPlace>>, codex: Awaited<ReturnType<typeof dotsPlace>>) => {
    for (const at of [claude, codex]) {
      expect(at.gap, "clear of the quiet row or the box").toBeGreaterThanOrEqual(-0.5);
      expect(at.under, "inside the pane").toBeGreaterThanOrEqual(-0.5);
    }
    expect({ top: codex.top, left: codex.left }).toEqual({ top: claude.top, left: claude.left });
  };

  test("New Tab, Claude's look: nothing over the box, the folder, computer and model one row under it", async () => {
    for (const variant of ["newtab-stage-claude", "newtab-claude"]) {
      const { page, close } = await open(variant);
      const layout = await page.evaluate(() => {
        const composer = document.querySelector(".nt-composer")!;
        const box = composer.querySelector(".nt-box")!.getBoundingClientRect();
        // Everything the composer draws over its box.
        const over = [...composer.querySelectorAll<HTMLElement>("*")].filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.height > 0 && rect.bottom <= box.top && !element.closest(".nt-box");
        });
        const middle = (selector: string) => {
          const rect = composer.querySelector(selector)?.getBoundingClientRect();
          return rect ? Math.round(rect.top + rect.height / 2) : undefined;
        };
        const rows = new Set(
          [".acpmux-location-picker:first-child", '.acpmux-location-picker[data-kind="computer"]', ".acpmux-model"].map(
            middle,
          ),
        );
        return {
          over: over.map((element) => element.className),
          rows: [...rows],
          underBox: [...rows].every((y) => y !== undefined && y > box.bottom),
          inFoot: composer.querySelectorAll(".acpmux-composer-foot :is(.nt-location, .acpmux-model)").length,
        };
      });
      expect({ variant, over: layout.over }).toEqual({ variant, over: [] });
      expect({ variant, rows: layout.rows.length, underBox: layout.underBox }).toEqual({
        variant,
        rows: 1,
        underBox: true,
      });
      expect(layout.inFoot).toBe(2);
      await close();
    }
  });

  test("New Tab: the dots keep one place on the page's edge in both looks, clear of the composer", async () => {
    const claude = await open("newtab-stage-claude");
    const atClaude = await dotsPlace(claude.page, ".nt-composer", ".nt-look-dots");
    await claude.close();
    const codex = await open("newtab-stage-codex");
    const atCodex = await dotsPlace(codex.page, ".nt-composer", ".nt-look-dots");
    await codex.close();
    samePlace(atClaude, atCodex);
  });

  test("in a chat the dots keep one place on the composer's edge in both looks, clear of it", async () => {
    const claude = await open("claude-chat", 600);
    const atClaude = await dotsPlace(claude.page, ".acpmux-composer", ".acpmux-look-dots");
    await claude.close();
    const codex = await open("codex-chat", 600);
    const atCodex = await dotsPlace(codex.page, ".acpmux-composer", ".acpmux-look-dots");
    await codex.close();
    samePlace(atClaude, atCodex);
  });

  test("arrow keys switch the look with the dots held in place and the keyboard on them; Escape goes back", async () => {
    // A chat: Claude's dot, then Codex's by ArrowRight and back by ArrowLeft.
    const chat = await open("claude-chat", 600);
    const { page } = chat;
    const form = ".acpmux-composer";
    const place = () => dotsPlace(page, form, ".acpmux-look-dots");
    const focused = () =>
      page.evaluate(() => {
        const active = document.activeElement as HTMLInputElement | null;
        if (active?.matches(".nt-style input[type=radio]")) return `dot:${active.value}`;
        if (active?.matches("[contenteditable], textarea")) return "prompt";
        return active?.tagName ?? "none";
      });
    await page.focus(`${form} .acpmux-look-dots input[value=claude]`);
    const start = await place();
    await page.keyboard.press("ArrowRight");
    await page.waitForSelector(`${form}[data-composer-look="codex"]`);
    await settle(page);
    expect(await focused()).toBe("dot:codex");
    const switched = await place();
    expect({ top: switched.top, left: switched.left }).toEqual({ top: start.top, left: start.left });
    await page.keyboard.press("ArrowLeft");
    await page.waitForFunction((selector) => !document.querySelector(`${selector}[data-composer-look]`), form);
    await settle(page);
    expect(await focused()).toBe("dot:claude");
    const back = await place();
    expect({ top: back.top, left: back.left }).toEqual({ top: start.top, left: start.left });
    await page.keyboard.press("Escape");
    await settle(page);
    expect(await focused()).toBe("prompt");
    await chat.close();

    // New Tab: the arrow keys reach Codex's look with the dots in place and the keyboard on them.
    const tab = await open("newtab-stage-claude");
    const newTab = tab.page;
    const dots = () => dotsPlace(newTab, ".nt-composer", ".nt-look-dots");
    await newTab.focus(".nt-look-dots input[value=claude]");
    const before = await dots();
    for (let press = 0; press < 3; press++) {
      if (await newTab.$('.nt-composer[data-composer-look="codex"]')) break;
      await newTab.keyboard.press("ArrowRight");
      await settle(newTab);
    }
    await newTab.waitForSelector('.nt-composer[data-composer-look="codex"]');
    expect(
      await newTab.evaluate(() => (document.activeElement as HTMLInputElement | null)?.matches(".nt-look-dots input")),
    ).toBe(true);
    const after = await dots();
    expect({ top: after.top, left: after.left }).toEqual({ top: before.top, left: before.left });
    expect(after.gap).toBeGreaterThanOrEqual(-0.5);
    await newTab.keyboard.press("Escape");
    await settle(newTab);
    expect(
      await newTab.evaluate(() => (document.activeElement as HTMLInputElement | null)?.matches(".nt-look-dots input")),
    ).toBe(false);
    await tab.close();
  });
});
