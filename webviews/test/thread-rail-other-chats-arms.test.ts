// l10n-allow-file: the visible copy the folded card reads.
// The prompt rail's arms for other chats' messages (incoming.experiment.ts), in Chromium over the
// gallery's runs of messages (agent-pane.thread-minimap-incoming-fold): in every arm each tick at rest
// shares one column, one x and one width (cmux#32637; leo-workspace design/session-rail.md "One
// column at rest"), the folding arms draw a run as one tick whose card reads "Received 3 messages",
// and the dimming arms draw other chats' resting ticks under the person's.
//
// With FAST_CHECKS_OUT set it keeps a still of each arm, at rest and with the first run hovered, and
// one side-by-side sheet of all of them (thread-rail-other-chats-arms.png).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-other-chats-arms.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.thread-minimap-incoming-fold";
  const EXPERIMENT = "thread-minimap-incoming";
  const ARMS = ["as-now", "secondary", "folded", "folded-secondary"] as const;
  const WIDTH = 1040;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("prompt rail: other chats' arms", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "rest" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Tick = { left: number; width: number; incoming: boolean; opacity: number };
  type Read = { ticks: Tick[]; card?: { from: string; prompt: string }; shots: Buffer[] };
  const out = process.env.FAST_CHECKS_OUT;

  const ticksOf = (page: Page): Promise<Tick[]> =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => {
        const bar = tick.querySelector<HTMLElement>(".acpmux-minimap__bar")!;
        const box = bar.getBoundingClientRect();
        return {
          left: Math.round(box.left * 2) / 2,
          width: Math.round(box.width * 2) / 2,
          incoming: tick.hasAttribute("data-incoming"),
          opacity: Number(getComputedStyle(bar).opacity),
        };
      }),
    );

  const read = async (arm: (typeof ARMS)[number]): Promise<Read> => {
    const page = await browser.newPage({ viewport: { width: WIDTH, height: 640 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "rest", width: WIDTH, reducedMotion: "true", exp: EXPERIMENT, arm })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(WIDTH - 10, 600);
      await page.evaluate(() => Promise.all(document.getAnimations().map((animation) => animation.finished)));
      const ticks = await ticksOf(page);
      const clip = { x: 0, y: 0, width: 520, height: 640 };
      const shots = [await page.screenshot({ clip })];
      await page.hover('[data-tick="3"]');
      await page.waitForSelector(".acpmux-minimap__card");
      const card = await page.evaluate(() => ({
        from: document.querySelector(".acpmux-minimap__from")?.textContent ?? "",
        prompt: document.querySelector(".acpmux-minimap__prompt")?.textContent ?? "",
      }));
      shots.push(await page.screenshot({ clip }));
      if (out) {
        writeFileSync(path.join(out, `thread-rail-other-chats-${arm}-rest.png`), shots[0]!);
        writeFileSync(path.join(out, `thread-rail-other-chats-${arm}-hover.png`), shots[1]!);
      }
      return { ticks, card, shots };
    } finally {
      await page.close();
    }
  };

  const reads = new Map<string, Promise<Read>>();
  const of = (arm: (typeof ARMS)[number]) => {
    let known = reads.get(arm);
    if (!known) reads.set(arm, (known = read(arm)));
    return known;
  };

  for (const arm of ARMS) {
    const fold = arm.startsWith("folded");
    const dim = arm.endsWith("secondary");
    test(`${arm}: every tick at rest shares one x and one width`, async () => {
      const { ticks } = await of(arm);
      // 14 turns: 8 of the person's and 6 from other chats (a run of three, a single, a run of two).
      expect(ticks.length).toBe(fold ? 8 + 3 : 14);
      expect(new Set(ticks.map((tick) => tick.left)).size).toBe(1);
      expect(new Set(ticks.map((tick) => tick.width)).size).toBe(1);
    });
    test(`${arm}: ${dim ? "other chats' resting ticks draw under the person's" : "other chats' ticks draw as the person's"}`, async () => {
      const { ticks } = await of(arm);
      // The faintest of each: a resting tick (the ones on screen are lit).
      const faintest = (incoming: boolean) =>
        Math.min(...ticks.filter((tick) => tick.incoming === incoming).map((tick) => tick.opacity));
      expect(ticks[3]!.incoming).toBe(true);
      if (dim) expect(faintest(true)).toBeLessThan(faintest(false));
      else expect(faintest(true)).toBe(faintest(false));
    });
    test(`${arm}: the first run's card`, async () => {
      const { card } = await of(arm);
      expect(card!.from).toBe("From lane-box-1/ux-owner");
      if (fold) expect(card!.prompt).toBe("Received 3 messages");
      else expect(card!.prompt).toContain("Status 4");
    });
  }

  test("a side-by-side sheet of every arm", async () => {
    const all = await Promise.all(ARMS.map((arm) => of(arm)));
    if (!out) return;
    const page = await browser.newPage({ viewport: { width: 4 * 540, height: 2 * 660 + 40 }, deviceScaleFactor: 1 });
    try {
      const cells = ARMS.map(
        (arm, i) =>
          `<figure><figcaption>${arm}${arm === "folded-secondary" ? " (default)" : ""}</figcaption>${all[i]!.shots.map(
            (shot) => `<img src="data:image/png;base64,${shot.toString("base64")}">`,
          ).join("")}</figure>`,
      ).join("");
      await page.setContent(
        `<style>body{margin:0;display:flex;gap:20px;background:#888;font:16px system-ui}figure{margin:0;display:flex;flex-direction:column;gap:10px}img{width:520px;height:640px}figcaption{height:20px}</style>${cells}`,
      );
      await page.screenshot({ path: path.join(out, "thread-rail-other-chats-arms.png"), fullPage: true });
    } finally {
      await page.close();
    }
  });
});
