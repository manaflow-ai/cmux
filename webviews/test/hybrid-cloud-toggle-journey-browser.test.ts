// cmux-web-test-timeout: 900
// l10n-allow-file: browser assertions on the gallery's English strings.
//
// A new user's journey with the cloud button, in a real browser on the real CSS (Leo, 2026-11-23:
// "a toggleable cloud button, maybe a rainbow cloud symbol..... that is dull when not toggled on,
// and when you toggle it on it becomes a rainbow or some hilariously satisfying toggle-on", and
// "you guys need to be absolutely exhaustively testing out what would a new user be seeing here?").
//
// The walk: New Tab, signed out (the name asks to sign in, the cloud is dull, a click changes
// nothing); signed in with no plan (the name offers the trial); a chat with Cloud on hand, the
// cloud dull; the person clicks it and it lights in the rainbow, with the arc rising once; it
// settles and stays lit; drawn again already on, it does not replay; a second click puts it out;
// under reduced motion it lights at once with nothing moving. Then the three-state control: Hybrid
// lights on a second click, Only in Cloud lights, Only on This Mac never does.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Variant =
  | "newtab-above-three-state-blocked-signed-out"
  | "newtab-above-three-state-blocked-no-plan"
  | "chat-above-off"
  | "chat-above-rainbow"
  | "chat-above-three-state";

/// What the eye reads off one cloud glyph: its paint, how strong it is, and whether it moves.
type Look = {
  fill: string;
  stroke: string;
  opacity: number;
  hues: number;
  moving: number;
};

await requireBrowserLane("hybrid-cloud-toggle-journey-browser.test.ts", async () => {
  const ENTRY = "agent-pane.hybrid-cloud-toggle";
  const VARIANTS = [
    "newtab-above-three-state-blocked-signed-out",
    "newtab-above-three-state-blocked-no-plan",
    "chat-above-off",
    "chat-above-rainbow",
    "chat-above-three-state",
  ] as const satisfies readonly Variant[];
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const variant of VARIANTS) await warmGalleryFrame(vite, ENTRY, { browser, params: { variant } });
    if (out) await mkdir(out, { recursive: true });
  }, 600_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(
    variant: Variant,
    {
      colorScheme = "dark",
      reducedMotion = "no-preference",
    }: {
      colorScheme?: "light" | "dark";
      reducedMotion?: "reduce" | "no-preference";
    } = {},
  ): Promise<Page> {
    const page = await browser.newPage({
      viewport: { width: 720, height: 260 },
      deviceScaleFactor: 2,
      reducedMotion,
    });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, {
        variant,
        colorScheme,
        width: 720,
        height: 260,
        // The frame emulates the system setting itself (src/gallery/frame/media.ts), over the browser's.
        reducedMotion: reducedMotion === "reduce" ? 1 : undefined,
      })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    return page;
  }

  /// The glyph the person looks at: the on/off cloud's shape, or the chosen segment's cloud.
  async function look(page: Page, selector: string): Promise<Look> {
    return page
      .locator(selector)
      .first()
      .evaluate((shape) => {
        const style = getComputedStyle(shape);
        // The paint a `url(#id)` fill points at: how many distinct colors its stops draw.
        const ref = /url\("?#([^")]+)"?\)/.exec(style.fill)?.[1];
        const gradient = ref ? document.getElementById(decodeURIComponent(ref)) : null;
        const stops = gradient
          ? [...gradient.querySelectorAll("stop")].map((stop) => getComputedStyle(stop).stopColor)
          : [];
        const glyph = shape.closest("button") ?? shape;
        return {
          fill: style.fill,
          stroke: style.stroke,
          opacity: Number(style.opacity),
          hues: new Set(stops).size,
          moving: glyph.getAnimations({ subtree: true }).filter((animation) => animation.playState === "running")
            .length,
        };
      });
  }

  async function shot(page: Page, name: string) {
    if (out)
      await page.screenshot({
        path: path.join(out, `cloud-journey-${name}.png`),
      });
  }

  const CLOUD = '[data-testid="hybrid-cloud-toggle"] .acpmux-hybrid-cloud__shape';
  const TOGGLE = '[data-testid="hybrid-cloud-toggle"]';
  const SEGMENT = (mode: string) =>
    `[data-testid="hybrid-tri-toggle"] .acpmux-hybrid-tri__segment[data-mode="${mode}"]`;

  for (const [variant, name] of [
    ["newtab-above-three-state-blocked-signed-out", "Sign In to Use Cloud"],
    ["newtab-above-three-state-blocked-no-plan", "Start Free Trial"],
  ] as const) {
    test(`a new user on New Tab, ${variant.replace(/.*blocked-/, "")}: the name says what to do, the cloud stays dull`, async () => {
      const page = await open(variant);
      try {
        const control = page.locator('[data-testid="hybrid-tri-toggle"]');
        await expect(control.getAttribute("data-blocked")).resolves.toBe(variant.replace(/.*blocked-/, ""));
        await expect(page.locator(".acpmux-hybrid-tri__name").innerText()).resolves.toBe(name);
        const before = await look(page, `${SEGMENT("cloud")} .acpmux-hybrid-tri__cloud`);
        expect(before.opacity).toBeLessThan(1);
        expect(before.fill).toBe("none");
        // A click on the cloud goes to sign-in or setup, never to a mode: nothing lights.
        await page.locator(SEGMENT("cloud")).click();
        await expect(control.getAttribute("data-mode")).resolves.toBe("auto");
        expect(await page.locator('[data-testid="hybrid-tri-toggle"] [data-lit]').count()).toBe(0);
        await shot(page, variant);
      } finally {
        await page.close();
      }
    });
  }

  for (const colorScheme of ["light", "dark"] as const) {
    test(`${colorScheme}: off is dull, the click lights the rainbow and plays the turn-on once`, async () => {
      const page = await open("chat-above-off", { colorScheme });
      try {
        const toggle = page.locator(TOGGLE);
        await expect(toggle.getAttribute("aria-checked")).resolves.toBe("false");
        const off = await look(page, CLOUD);
        expect(off.opacity).toBeLessThan(1);
        expect(off.fill).toBe("none");
        expect(off.hues).toBe(0);
        expect(off.moving).toBe(0);
        await shot(page, `off-${colorScheme}`);

        // The click and the first frame after it in one page task: the turn-on is 240 ms, shorter
        // than a few round trips to the browser.
        const turning = await page.locator(TOGGLE).evaluate(
          (button) =>
            new Promise<{
              checked: string | null;
              lit: boolean;
              fresh: boolean;
              moving: string[];
            }>((resolve) => {
              (button as HTMLButtonElement).click();
              // raf-read: the click's first frame, before the 240 ms turn-on ends; it reads attributes and
              // running animations, not layout, so a painted-frame wait would only arrive late.
              requestAnimationFrame(() =>
                resolve({
                  checked: button.getAttribute("aria-checked"),
                  lit: button.hasAttribute("data-lit"),
                  fresh: button.hasAttribute("data-fresh"),
                  moving: button
                    .getAnimations({ subtree: true })
                    .filter((animation) => animation.playState === "running")
                    .map((animation) => (animation as CSSAnimation).animationName ?? ""),
                }),
              );
            }),
        );
        expect(turning.checked).toBe("true");
        expect(turning.lit).toBe(true);
        expect(turning.fresh).toBe(true);
        // The turn-on: the cloud's settle and the arc rising behind it.
        expect(turning.moving).toEqual(
          expect.arrayContaining(["acpmux-hybrid-settle", "acpmux-hybrid-arc-show", "acpmux-hybrid-arc-draw"]),
        );

        // It settles: the turn-on disarms and the cloud stays lit, in every color of the rainbow.
        await page.waitForFunction(
          (selector) => !document.querySelector(selector)?.hasAttribute("data-fresh"),
          TOGGLE,
          { timeout: 10_000 },
        );
        const on = await look(page, CLOUD);
        expect(on.opacity).toBe(1);
        expect(on.fill).toMatch(/^url\(/);
        expect(on.hues).toBeGreaterThanOrEqual(5);
        expect(on.moving).toBe(0);
        expect(on.fill).not.toBe(off.fill);
        await shot(page, `on-${colorScheme}`);

        // A second click puts it out: dull again, and nothing plays.
        await toggle.click();
        await expect(toggle.getAttribute("aria-checked")).resolves.toBe("false");
        const again = await look(page, CLOUD);
        expect(again.fill).toBe("none");
        expect(again.moving).toBe(0);
      } finally {
        await page.close();
      }
    });
  }

  test("a chat drawn already on is lit and does not replay the turn-on", async () => {
    const page = await open("chat-above-rainbow");
    try {
      const toggle = page.locator(TOGGLE);
      await expect(toggle.getAttribute("aria-checked")).resolves.toBe("true");
      expect(await toggle.getAttribute("data-fresh")).toBeNull();
      const on = await look(page, CLOUD);
      expect(on.fill).toMatch(/^url\(/);
      expect(on.hues).toBeGreaterThanOrEqual(5);
      expect(on.moving).toBe(0);
    } finally {
      await page.close();
    }
  });

  // The app hands the page its Reduce Motion setting on the root (ui/motion/motionMode.ts): the
  // gallery frame sets "full" there, so each case sets the root itself. "system" leaves the root
  // allowing motion and asks only the system's prefers-reduced-motion.
  for (const [setting, root, reducedMotion] of [
    ["the app's Reduce Motion", "reduced", "no-preference"],
    ["the app's motion off", "off", "no-preference"],
    ["the system's Reduce Motion", "full", "reduce"],
  ] as const)
    test(`${setting}: the click lights it at once and nothing moves`, async () => {
      const page = await open("chat-above-off", { reducedMotion });
      try {
        await page.evaluate((value) => document.documentElement.setAttribute("data-cmux-motion", value), root);
        // Read in the click's first frame: lit at once means no fade up from the dull 0.6 either.
        const on = await page.locator(TOGGLE).evaluate(
          (button) =>
            new Promise<{ fill: string; opacity: number; moving: string[] }>((resolve) => {
              (button as HTMLButtonElement).click();
              // raf-read: the click's first frame is the point (lit at once, no fade); it reads computed
              // paint and animations, not layout.
              requestAnimationFrame(() => {
                const shape = button.querySelector(".acpmux-hybrid-cloud__shape")!;
                resolve({
                  fill: getComputedStyle(shape).fill,
                  opacity: Number(getComputedStyle(shape).opacity),
                  // Keyframe animations only: the button's quick ink fade is a hover fill, which
                  // Reduce Motion keeps (ui/motion/motion.css stills hover fills only when motion is off).
                  moving: button
                    .getAnimations({ subtree: true })
                    .filter((animation) => "animationName" in animation)
                    .map((animation) => {
                      const target = (animation.effect as KeyframeEffect | null)?.target as Element | null;
                      return `${(animation as CSSAnimation).animationName} on ${target?.getAttribute("class") ?? "?"}`;
                    }),
                });
              });
            }),
        );
        expect(on.fill).toMatch(/^url\(/);
        expect(on.opacity).toBe(1);
        expect(on.moving).toEqual([]);
      } finally {
        await page.close();
      }
    });

  test("the three-state control: Hybrid lights on a second click, Only in Cloud lights, This Mac never does", async () => {
    const page = await open("chat-above-three-state");
    try {
      const control = page.locator('[data-testid="hybrid-tri-toggle"]');
      const hybrid = page.locator(SEGMENT("auto"));
      await expect(control.getAttribute("data-mode")).resolves.toBe("auto");
      expect(await hybrid.getAttribute("data-lit")).toBeNull();
      const dull = await look(page, `${SEGMENT("auto")} .acpmux-hybrid-tri__cloud`);
      expect(dull.fill).toBe("none");

      await hybrid.click();
      await expect(hybrid.getAttribute("data-lit")).resolves.toBe("");
      await expect(page.locator(".acpmux-hybrid-tri__name").innerText()).resolves.toBe("Keep Running");
      await page.waitForFunction(
        (selector) => !document.querySelector(selector)?.hasAttribute("data-fresh"),
        SEGMENT("auto"),
        { timeout: 10_000 },
      );
      const lit = await look(page, `${SEGMENT("auto")} .acpmux-hybrid-tri__cloud`);
      expect(lit.fill).toMatch(/^url\(/);
      expect(lit.hues).toBeGreaterThanOrEqual(5);
      await shot(page, "three-state-lit");

      await page.locator(SEGMENT("cloud")).click();
      await expect(control.getAttribute("data-mode")).resolves.toBe("cloud");
      await expect(page.locator(SEGMENT("cloud")).getAttribute("data-lit")).resolves.toBe("");

      await page.locator(SEGMENT("local")).click();
      await expect(control.getAttribute("data-mode")).resolves.toBe("local");
      expect(await page.locator('[data-testid="hybrid-tri-toggle"] [data-lit]').count()).toBe(0);
    } finally {
      await page.close();
    }
  });
});
