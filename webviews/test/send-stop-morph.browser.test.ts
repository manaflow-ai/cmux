// cmux-web-test-timeout: 240
// l10n-allow-file: test prompts, not shipped UI.
// The composer's one send slot morphs between Send and Stop (Leo, 2026-11-07: "At the very least,
// like the Enter to the Stop button, I like. I think it would be cool. You know, a fast animation"),
// in the real Composer laid out by Chromium (test/browser/send-stop-morph.harness.tsx):
// - a turn starting turns Send into Stop, and its end turns Stop back into Send, each with an
//   animation that ends within 200 ms, while the button's box stays where it is;
// - in Claude's look, Return's ↵ turns into the turn's Stop, and the first letter typed mid-turn
//   turns Stop into ↵;
// - nothing animates on the composer's first draw or on a chat switch, and under Reduce Motion the
//   glyph swaps in one frame.
// With CMUX_SEND_STOP_MORPH_CAPTURE_DIR set it writes mid-morph stills.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("send-stop-morph.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-stop-morph: skipping (run `bunx playwright install chromium`)");
    describe.skip("send stop morph", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const captureDir = process.env.CMUX_SEND_STOP_MORPH_CAPTURE_DIR;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/send-stop-morph.html");
    browser = await chromium.launch({ headless: true });
    if (captureDir) await mkdir(captureDir, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type State = { working?: boolean; sessionId?: string; look?: "claude" | "codex" };

  async function open(initial: State, reducedMotion: "reduce" | "no-preference" = "no-preference"): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 700, height: 360 }, deviceScaleFactor: 2, reducedMotion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/send-stop-morph.html`);
    await page.waitForFunction(() => "__set" in window);
    await set(page, initial);
    await page.waitForSelector(".acpmux-composer-bar", { state: "attached" });
    await settled(page);
    return page;
  }

  /** Past SETTLE_MS (300 ms) since the chat was drawn or switched: a change now is a change, not
   *  the chat's state arriving (composer/SendSlotGlyph.tsx). */
  const settled = (page: Page) =>
    page.waitForFunction(() => performance.now() - (window as unknown as { __scopeAt: number }).__scopeAt > 320);

  const set = (page: Page, next: State) =>
    page.evaluate((value) => (window as unknown as { __set(next: unknown): void }).__set(value), next);

  type Frame = {
    t: number;
    kind: "stop" | "send" | "none";
    rect: { x: number; y: number; width: number; height: number } | null;
    animations: number;
    longest: number;
    layers: number;
  };

  /** Applies `change` (in the page), then reads the slot on every frame for `ms`. */
  async function trace(page: Page, change: State | null, ms = 320): Promise<Frame[]> {
    return page.evaluate(
      async ({ change, ms }) => {
        const read = (t: number) => {
          const button = document.querySelector<HTMLElement>(".acpmux-composer-bar .acpmux-send");
          const box = button?.getBoundingClientRect();
          const animations = button ? button.getAnimations({ subtree: true }) : [];
          const glyph = button?.querySelectorAll(".acpmux-icon, .cv-spinner") ?? [];
          return {
            t,
            kind: !button ? "none" : button.classList.contains("acpmux-cancel") ? "stop" : "send",
            rect: box ? { x: box.x, y: box.y, width: box.width, height: box.height } : null,
            animations: animations.length,
            longest: Math.max(
              0,
              ...animations.map((animation) => Number(animation.effect?.getComputedTiming().endTime ?? 0)),
            ),
            layers: button?.querySelectorAll(".acpmux-send-layer, [data-send-morph]").length ?? 0,
            glyphs: glyph.length,
          };
        };
        const frames: unknown[] = [];
        if (change) (window as unknown as { __set(next: unknown): void }).__set(change);
        const start = performance.now();
        await new Promise<void>((done) => {
          // The test samples the transition itself, frame by frame: the button's box and running
          // animations, as a frame's callback sees them for the frame it draws.
          // raf-read: per-frame sampling of a running animation is the subject of this test.
          const tick = () => {
            const t = performance.now() - start;
            frames.push(read(t));
            if (t >= ms) done();
            // raf-read: the next sample of the same running animation.
            else requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        });
        return frames;
      },
      { change, ms },
    ) as Promise<Frame[]>;
  }

  /** Every frame drew the slot in one box, it animated, and it was settled by 200 ms (+ one frame). */
  function expectMorph(frames: Frame[], to: "stop" | "send") {
    const drawn = frames.filter((frame) => frame.kind !== "none");
    expect(drawn.length).toBeGreaterThan(5);
    expect(drawn.every((frame) => frame.kind === to)).toBe(true);
    const first = drawn[0]!.rect!;
    for (const frame of drawn) expect(frame.rect).toEqual(first);
    const animating = drawn.filter((frame) => frame.animations > 0);
    expect(animating.length).toBeGreaterThan(0);
    expect(Math.max(...drawn.map((frame) => frame.longest))).toBeLessThanOrEqual(200);
    const settled = drawn.filter((frame) => frame.t > 220);
    expect(settled.length).toBeGreaterThan(0);
    for (const frame of settled) {
      expect(frame.animations).toBe(0);
      expect(frame.layers).toBe(0);
    }
  }

  async function capture(page: Page, name: string, change: State, at: number) {
    if (!captureDir) return;
    await set(page, change);
    await page.waitForTimeout(at); // fixed-wait: a still `at` ms into the 180 ms morph; the time is the subject.
    await page.locator(".acpmux-composer-box").screenshot({ path: path.join(captureDir, `${name}.png`) });
  }

  const startTurn: State = { working: true };
  const endTurn: State = { working: false };

  test("Codex's look: a turn's start morphs Send into Stop and its end morphs Stop into Send", async () => {
    const page = await open({ look: "codex", working: false });
    expectMorph(await trace(page, startTurn), "stop");
    expectMorph(await trace(page, endTurn), "send");
    await capture(page, "codex-send-to-stop-mid", startTurn, 70);
    await page.close();
  });

  test("Claude's look: Return's ↵ morphs into the turn's Stop, and a letter typed mid-turn into ↵", async () => {
    const page = await open({ look: "claude", working: false });
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await page.keyboard.type("Ship it");
    await page.waitForSelector(".acpmux-composer-bar .acpmux-send.acpmux-send-ready", { state: "attached" });
    // Return clears the draft at once; acpmux's turn opens a moment later (its round trip).
    await page.evaluate(() =>
      // fixed-wait: acpmux's turn start arrives a beat after the send clears the slot, as in the app.
      setTimeout(() => (window as unknown as { __set(next: unknown): void }).__set({ working: true }), 60),
    );
    await page.keyboard.press("Enter");
    const sent = await trace(page, null, 400);
    expect(await page.evaluate(() => (window as unknown as { __sends(): string[] }).__sends())).toEqual(["Ship it"]);
    const stopAt = sent.find((frame) => frame.kind === "stop")?.t ?? 0;
    expectMorph(
      sent.filter((frame) => frame.kind === "stop").map((frame) => ({ ...frame, t: frame.t - stopAt })),
      "stop",
    );
    expect(sent.at(-1)?.kind).toBe("stop");
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").focus();
    await page.keyboard.type("n");
    const frames = await trace(page, null, 320);
    // The letter landed before the trace began; the morph is still running at its first frame.
    expect(frames[0]!.kind).toBe("send");
    expect(frames[0]!.animations).toBeGreaterThan(0);
    expect(frames.filter((frame) => frame.t > 220).every((frame) => frame.layers === 0 && frame.animations === 0)).toBe(
      true,
    );
    await page.close();
  });

  test("nothing animates on the first draw or on a chat switch", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 700, height: 360 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/send-stop-morph.html`);
    await page.waitForFunction(() => "__set" in window);
    const mount = await trace(page, { look: "codex", working: true }, 200);
    expect(mount.every((frame) => frame.layers === 0 && frame.animations === 0)).toBe(true);
    // Past the mount's settle window, so the switch below is what keeps the glyph still.
    await settled(page);
    // Another chat, idle where this one ran: its Send is drawn at once.
    const switched = await trace(page, { sessionId: "chat-b", working: false }, 200);
    expect(switched.at(-1)?.kind).toBe("send");
    expect(switched.every((frame) => frame.layers === 0 && frame.animations === 0)).toBe(true);
    await page.close();
  });

  test("Reduce Motion swaps the glyph in one frame", async () => {
    const page = await open({ look: "codex", working: false }, "reduce");
    const frames = await trace(page, startTurn, 200);
    expect(frames[0]!.kind).toBe("stop");
    expect(frames.every((frame) => frame.layers === 0 && frame.animations === 0)).toBe(true);
    await page.close();
  });
});
