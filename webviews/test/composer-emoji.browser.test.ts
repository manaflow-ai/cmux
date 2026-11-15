// cmux-web-test-timeout: 300
// l10n-allow-file: test prompts, not shipped UI.
// Emoji by shortcode in the prompt (Leo, 2026-11-03: "yo wtf i want this kind of feature in
// cmux-next too", of Claude desktop's `:` popover), in the real gallery stages laid out by Chromium:
// - `:tedd` lists 🧸 :teddy_bear: first, in a compact menu over the typed `:`, inside the composer;
// - `:DD` lists 😆 first and never the middle finger, with no row chosen (Return still sends);
// - Return on a chosen row writes the glyph; a time or a URL opens nothing.
// With FAST_CHECKS_OUT set it writes 2x stills of every look, light and dark, before it asserts.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";

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
    return page.evaluate(() => {
      const prompt = document.querySelector(".acpmux-composer-prompt [contenteditable='true']");
      const menu = document.querySelector<HTMLElement>(".acpmux-emoji-menu");
      const box = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect();
      const rect = menu?.getBoundingClientRect();
      return {
        text: prompt?.textContent ?? "",
        active: prompt?.getAttribute("aria-activedescendant") ?? null,
        rows: [...document.querySelectorAll<HTMLElement>(".acpmux-emoji-row")].map((row) =>
          row.getAttribute("aria-label"),
        ),
        menu: rect ? { left: rect.left, right: rect.right, bottom: rect.bottom, width: rect.width } : null,
        box: box ? { left: box.left, right: box.right, top: box.top } : null,
      };
    });
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

  test(":tedd lists the teddy bear first, none chosen, in a compact menu inside the composer", async () => {
    const page = await stage("tedd");
    const state = await read(page);
    expect(state.rows[0]).toBe("🧸 :teddy_bear:");
    // No row chosen until the arrows choose one, so Return sends the text as typed.
    expect(state.active).toBeNull();
    expect(state.menu!.width).toBeLessThan(260);
    expect(state.menu!.left).toBeGreaterThanOrEqual(state.box!.left - 1);
    expect(state.menu!.right).toBeLessThanOrEqual(state.box!.right + 1);
    // Over the typed `:`, not at the box's left edge (the text starts after +).
    expect(state.menu!.left).toBeGreaterThan(state.box!.left + 40);
    expect(state.menu!.bottom).toBeLessThanOrEqual(state.box!.top);
    await page.close();
  });

  test(":DD lists a laughing face, never the middle finger, with no row chosen", async () => {
    const page = await stage("emoticon-dd");
    const state = await read(page);
    expect(state.rows[0]).toBe("😆 :laughing:");
    expect(state.rows.some((row) => row?.includes("middle_finger") || row?.includes(":fu:"))).toBe(false);
    expect(state.active).toBeNull();
    await page.close();
  });

  for (const variant of ["arrow-return", "return-sends", "emoticon-tab", "arrows-escape", "no-trigger", "heart"])
    test(`play ${variant} passes`, async () => {
      const page = await stage(variant);
      // What the play did, not how fast the runner drew it: a frame over 33 ms on the shared runner
      // fails the gallery's own grade (play.ts) but not this test (support/galleryPlay.ts, cx-mfkky).
      const report = await page.evaluate(() => JSON.stringify(window.cmuxGalleryPlayReport ?? {}));
      expect([variant, playFailures(report)]).toEqual([variant, []]);
      expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).not.toBe("error");
      if (variant === "arrow-return") expect((await read(page)).text).toContain("Ship it 🧸");
      if (variant === "return-sends") expect((await read(page)).text).not.toContain("🧸");
      if (variant === "heart") expect((await read(page)).rows[0]).toBe("❤️ :heart:");
      await page.close();
    });
});
