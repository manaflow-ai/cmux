// cmux-web-test-timeout: 300
// l10n-allow-file: test prompts, not shipped UI.
// Emoji by shortcode in the prompt (Leo, 2026-11-03: "yo wtf i want this kind of feature in
// cmux-next too", of Claude desktop's `:` popover), in the real gallery stages laid out by Chromium:
// - `:tedd` lists 🧸 :teddy_bear: first, in a compact menu over the typed `:`, inside the composer;
// - `:DD` lists 😆 first and never the middle finger;
// - the first row is always highlighted and Return writes it, never sends (Leo, 2026-11-20: "i click
//   enter and it should do it"); Esc or typing on keeps the text, and an edit back to the same text
//   brings the list back; a time or a URL opens nothing;
// - while the list shows, the system's own completion (autocorrect, inline predictions) is off.
// With FAST_CHECKS_OUT set it writes 2x stills of every look, light and dark, before it asserts.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("composer-emoji.browser.test.ts", async () => {
  setDefaultTimeout(150_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-emoji: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer emoji", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.composer-emoji";
  const WIDTH = 760;
  const HEIGHT = 560;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "tedd" } });
    if (out) await mkdir(out, { recursive: true });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function stage(variant: string, look = "caret", colorScheme: "light" | "dark" = "dark"): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 2 });
    // No recent picks carried in (emojiShortcodes.ts rememberEmoji).
    await page.addInitScript(() => localStorage.removeItem("cmux.acpmux.recentEmoji"));
    const params = { variant, colorScheme, reducedMotion: "true", width: WIDTH, height: HEIGHT };
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { ...params, exp: "emoji-shortcode-look", arm: look })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    return page;
  }

  function read(page: Page) {
    return page.evaluate(
      ({ COMPOSER_EDITOR }) => {
        const prompt = document.querySelector(COMPOSER_EDITOR);
        const menu = document.querySelector<HTMLElement>(".acpmux-emoji-menu");
        const box = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect();
        const rect = menu?.getBoundingClientRect();
        return {
          text: prompt?.textContent ?? "",
          active: prompt?.getAttribute("aria-activedescendant") ?? null,
          rows: [...document.querySelectorAll<HTMLElement>(".acpmux-emoji-row")].map((row) =>
            row.getAttribute("aria-label"),
          ),
          highlighted: [...document.querySelectorAll(".acpmux-emoji-row")].findIndex((row) =>
            row.classList.contains("acpmux-slash-active"),
          ),
          native: prompt
            ? {
                spellcheck: prompt.getAttribute("spellcheck"),
                autocorrect: prompt.getAttribute("autocorrect"),
                writingsuggestions: prompt.getAttribute("writingsuggestions"),
              }
            : null,
          menu: rect ? { left: rect.left, right: rect.right, bottom: rect.bottom, width: rect.width } : null,
          box: box ? { left: box.left, right: box.right, top: box.top } : null,
        };
      },
      { COMPOSER_EDITOR },
    );
  }

  test("stills of every look, light and dark (with FAST_CHECKS_OUT)", async () => {
    if (!out) return;
    for (const look of ["caret", "wide", "strip"])
      for (const variant of ["tedd", "emoticon-dd"])
        for (const colorScheme of ["light", "dark"] as const) {
          const page = await stage(variant, look, colorScheme);
          const { menu, box } = await read(page);
          const top = Math.max(0, (box?.top ?? 0) - 260);
          await page.screenshot({
            path: path.join(out, `emoji-${look}-${variant}-${colorScheme}.png`),
            clip: { x: 0, y: top, width: WIDTH, height: Math.min(HEIGHT - top, 360) },
          });
          console.log(`composer-emoji ${look} ${variant} ${colorScheme}: ${JSON.stringify(menu)}`);
          await page.close();
        }
  });

  test(":tedd lists the teddy bear first, highlighted, in a compact menu inside the composer", async () => {
    const page = await stage("tedd");
    const state = await read(page);
    expect(state.rows[0]).toBe("🧸 :teddy_bear:");
    // The first row is highlighted from the start, so Return writes it (Leo, 2026-11-20).
    expect(state.active).toBe("acpmux-emoji-0");
    expect(state.highlighted).toBe(0);
    expect(state.menu!.width).toBeLessThan(260);
    expect(state.menu!.left).toBeGreaterThanOrEqual(state.box!.left - 1);
    expect(state.menu!.right).toBeLessThanOrEqual(state.box!.right + 1);
    // Over the typed `:`, not at the box's left edge (the text starts after +).
    expect(state.menu!.left).toBeGreaterThan(state.box!.left + 40);
    expect(state.menu!.bottom).toBeLessThanOrEqual(state.box!.top);
    await page.close();
  });

  test(":plead lists 🥺 first, highlighted, and turns off the system's own completion while it shows", async () => {
    const page = await stage("pleading");
    const state = await read(page);
    expect(state.rows[0]).toBe("🥺 :pleading_face:");
    expect(state.active).toBe("acpmux-emoji-0");
    expect(state.highlighted).toBe(0);
    // One completion UI: no autocorrect bubble or inline prediction under the caret.
    expect(state.native).toEqual({ spellcheck: "false", autocorrect: "off", writingsuggestions: "false" });
    await page.close();
  });

  test(":DD lists a laughing face, never the middle finger, highlighted", async () => {
    const page = await stage("emoticon-dd");
    const state = await read(page);
    expect(state.rows[0]).toBe("😆 :laughing:");
    expect(state.rows.some((row) => row?.includes("middle_finger") || row?.includes(":fu:"))).toBe(false);
    expect(state.active).toBe("acpmux-emoji-0");
    await page.close();
  });

  for (const variant of [
    "arrow-return",
    "return-picks",
    "emoticon-tab",
    "arrows-escape",
    "escape-retype",
    "type-past",
    "no-trigger",
    "heart",
  ])
    test(`play ${variant} passes`, async () => {
      const page = await stage(variant);
      // What the play did, not how fast the runner drew it: a frame over 33 ms on the shared runner
      // fails the gallery's own grade (play.ts) but not this test (support/galleryPlay.ts, cx-mfkky).
      const report = await page.evaluate(() => JSON.stringify(window.cmuxGalleryPlayReport ?? {}));
      expect([variant, playFailures(report)]).toEqual([variant, []]);
      expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).not.toBe("error");
      if (variant === "return-picks") expect((await read(page)).text).toContain("aw 🥺");
      if (variant === "type-past") expect((await read(page)).text).toContain("aw :pl ok");
      if (variant === "heart") expect((await read(page)).rows[0]).toBe("❤️ :heart:");
      await page.close();
    });
});
