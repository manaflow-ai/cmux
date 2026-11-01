// cmux-web-test-timeout: 240
// The composer's `/` and `@` lists draw out of the composer box's glass (backdropLayer.tsx). The
// box's backdrop-filter makes it a backdrop root, so a list inside it frosted only the box and the
// transcript read sharp through it, where the mode and model menus (portaled out) frost it. In the
// real gallery stages, laid out by Chromium, each list (the chat's `/` and `@`, New Tab's `/`):
// - is not inside the box, and no ancestor of it is a backdrop root;
// - still stands where it stood inside the box: 6 px above it, on its left and right edges;
// - still picks a row on a press, with the prompt keeping the keyboard (composerFocus.ts lets a
//   press on the list's layer through, or the blur would close the list first).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("composer-lists-out-of-glass.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-lists-out-of-glass: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer lists out of glass", () => test("chromium", () => {}));
    return;
  }
  /** Each list: a gallery state, how it opens (the state's play, or a typed `/`), its box. */
  const LISTS = {
    slash: {
      entry: "agent-pane.composer",
      variant: "slash-menu-fast-off",
      type: undefined,
      list: "#acpmux-slash-menu",
      box: ".acpmux-composer-box",
    },
    mention: {
      entry: "agent-pane.composer",
      variant: "mention-recent-chats",
      type: undefined,
      list: "#acpmux-mention-menu",
      box: ".acpmux-composer-box",
    },
    "new-tab": {
      entry: "agent-pane.new-tab",
      variant: "start-refused",
      type: "/",
      list: "#acpmux-slash-menu",
      box: ".nt-box",
    },
  } as const;
  type List = keyof typeof LISTS;
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, LISTS.slash.entry, { browser, params: { variant: LISTS.slash.variant } });
    await warmGalleryFrame(vite, LISTS["new-tab"].entry, { browser, params: { variant: LISTS["new-tab"].variant } });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A list's gallery state with the list open and its rows in. */
  async function opened(name: List): Promise<Page> {
    const { entry, variant, type, list } = LISTS[name];
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, reducedMotion: "true" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
    if (type) {
      await page.locator(`${LISTS[name].box} [contenteditable='true']`).first().click();
      // The state keeps a typed prompt (the refused start's): a `/` opens the list only first.
      await page.keyboard.press("ControlOrMeta+a");
      await page.keyboard.press("Backspace");
      await page.keyboard.type(type);
    }
    await page.waitForSelector(`${list} [role=option]`);
    return page;
  }

  for (const name of Object.keys(LISTS) as List[])
    test(`the ${name} list draws out of the box's glass, 6 px above the box on its edges`, async () => {
      const page = await opened(name);
      const { list, box } = LISTS[name];
      const found = await page.evaluate(
        ({ list, box }) => {
          const menu = document.querySelector<HTMLElement>(list)!;
          const card = document.querySelector<HTMLElement>(box)!;
          // A backdrop root (Filter Effects 2), as backdropLayer.tsx isBackdropRoot reads one.
          const roots: string[] = [];
          for (let node = menu.parentElement; node; node = node.parentElement) {
            const css = getComputedStyle(node);
            const set = (value: string) => !!value && value !== "none";
            if (
              set(css.backdropFilter) ||
              set(css.filter) ||
              set(css.maskImage) ||
              set(css.clipPath) ||
              Number.parseFloat(css.opacity) < 1 ||
              css.mixBlendMode !== "normal" ||
              /backdrop-filter|filter|opacity|mask/.test(css.willChange)
            )
              roots.push(String(node.className) || node.tagName);
          }
          const m = menu.getBoundingClientRect();
          const b = card.getBoundingClientRect();
          return {
            inBox: card.contains(menu),
            roots,
            ownBlur: getComputedStyle(menu).backdropFilter,
            gap: b.top - m.bottom,
            left: m.left - b.left,
            right: m.right - b.right,
            above: m.bottom <= b.top,
          };
        },
        { list, box },
      );
      console.log(`composer-lists-out-of-glass: ${name} ${JSON.stringify(found)}`);
      expect(found.inBox).toBe(false);
      expect(found.roots).toEqual([]);
      expect(found.ownBlur).not.toBe("none");
      expect(found.above).toBe(true);
      expect(Math.abs(found.gap - 6)).toBeLessThanOrEqual(1);
      expect(Math.abs(found.left)).toBeLessThanOrEqual(1);
      expect(Math.abs(found.right)).toBeLessThanOrEqual(1);
      await page.close();
    });

  test("a press on a slash row picks it and the prompt keeps the keyboard", async () => {
    const page = await opened("slash");
    const row = page.locator("#acpmux-slash-menu [role=option]").nth(1);
    const name = (await row.locator(".acpmux-slash-name").textContent())!.trim();
    await row.click();
    const prompt = page.locator(".acpmux-composer-box [contenteditable='true']").first();
    await page.waitForFunction(() => !document.querySelector("#acpmux-slash-menu"));
    const after = await prompt.evaluate((field) => ({
      text: field.textContent ?? "",
      focused: document.activeElement === field,
    }));
    console.log(`composer-lists-out-of-glass: picked ${name} ${JSON.stringify(after)}`);
    expect(after.focused).toBe(true);
    expect(after.text.trim().length).toBeGreaterThan(1);
    expect(after.text.startsWith("/")).toBe(true);
    await page.close();
  });

  test("the list follows the box as the draft grows while it is open", async () => {
    const page = await opened("mention");
    const prompt = page.locator(".acpmux-composer-box [contenteditable='true']").first();
    const place = () =>
      page.evaluate(() => {
        const m = document.querySelector("#acpmux-mention-menu")!.getBoundingClientRect();
        const b = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        return { gap: b.top - m.bottom, left: m.left - b.left, right: m.right - b.right, box: b.height };
      });
    const start = await place();
    // A query past the line's width wraps, and the box grows under the open list.
    await prompt.press("End");
    await page.keyboard.type("x".repeat(240));
    await page.waitForFunction((height) => {
      const b = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      return b.height > height + 10 && document.querySelector("#acpmux-mention-menu") !== null;
    }, start.box);
    const grown = await place();
    console.log(`composer-lists-out-of-glass: draft grew ${JSON.stringify({ start, grown })}`);
    expect(Math.abs(grown.gap - 6)).toBeLessThanOrEqual(1);
    expect(Math.abs(grown.left)).toBeLessThanOrEqual(1);
    expect(Math.abs(grown.right)).toBeLessThanOrEqual(1);
    await page.close();
  });
});
