// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The compact rail's tick states and entrance, in a real engine. A bookmarked prompt's tick is the
// resting grey a step brighter, as ChatGPT's rail draws one, never the text at full brightness, and
// turns the text only when hovered (Leo 2026-10-25: "when I bookmark something, it shouldn't be just
// at the full brightness ... It should be, like, grayed out. That's how ChatGPT does it"). The ticks
// come in on an eased curve with a small bounded stagger, not a linear pop (Leo 2026-10-25: "those
// sort of lines pop up. There should be a little bit more easing"), and not at all under Reduce Motion.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-tick-states.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-minimap-tick-states: skipping (run `bunx playwright install chromium`)");
    describe.skip("thread minimap tick states", () => test("chromium", () => {}));
    return;
  }
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
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  /// Eighteen prompts, rows `user-<seq>` (seq 1 to 18) as acpmux names them, so a bookmark can name one.
  const rows = Array.from({ length: 18 }, (_, index) => [
    row(`user-${index + 1}`, "user", `Reply with only the word ok and the number ${index + 1}. No tools.`),
    row(`answer-${index + 1}`, "assistant", `ok ${index + 1}\n\nA second paragraph so the turn has some height.`),
    row(`summary-${index + 1}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ]).flat();

  /// The pane at the chat's top with prompt 13 (tick 12, below the band) bookmarked. `hold` pauses the
  /// ticks' entrance where it starts, so a test can read it.
  async function open(options: { reduce?: boolean; hold?: boolean; motion?: string } = {}): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await page.emulateMedia({ reducedMotion: options.reduce ? "reduce" : "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    if (options.motion)
      await page.evaluate(
        (motion) => document.documentElement.setAttribute("data-cmux-motion", motion),
        options.motion,
      );
    if (options.hold)
      await page.addStyleTag({
        content: ".acpmux-minimap__bar, .acpmux-minimap__dot { animation-play-state: paused !important; }",
      });
    await page.evaluate((shown) => {
      const win = window as unknown as { __showRows(rows: unknown): void; __setMarks(seqs: number[]): void };
      win.__setMarks([13]);
      win.__showRows(shown);
    }, rows);
    await page.waitForSelector('[data-tick="12"][data-bookmarked]');
    await page.evaluate(() => {
      document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0;
    });
    return page;
  }

  /// A tick's bar and dot as drawn once its entrance is over: color and opacity.
  const look = (page: Page, index: number) =>
    page.evaluate(async (at) => {
      await Promise.all(
        document
          .getAnimations()
          .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
          .map((animation) => animation.finished.catch(() => undefined)),
      );
      const tick = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!;
      const bar = getComputedStyle(tick.querySelector(".acpmux-minimap__bar")!);
      const dotNode = tick.querySelector(".acpmux-minimap__dot");
      const dot = dotNode ? getComputedStyle(dotNode) : undefined;
      return {
        tone: tick.dataset.tone,
        color: bar.backgroundColor,
        opacity: Number(bar.opacity),
        dot: dot ? { color: dot.backgroundColor, opacity: Number(dot.opacity) } : undefined,
      };
    }, index);

  test("a bookmarked tick is the resting grey a step brighter, and the text only when hovered", async () => {
    const page = await open();
    const rest = await look(page, 14);
    const marked = await look(page, 12);
    const text = await page.evaluate(() =>
      getComputedStyle(document.documentElement).getPropertyValue("--agent-text").trim(),
    );
    expect(rest.tone).toBe("rest");
    expect(marked.tone).toBe("rest");
    // The resting color, never the text, at a grey step over rest (40%) and under the lit band (75%).
    expect(marked.color).toBe(rest.color);
    expect(marked.opacity).toBeGreaterThan(rest.opacity);
    expect(marked.opacity).toBeLessThan(0.75);
    expect(marked.dot).toEqual({ color: rest.color, opacity: marked.opacity });
    // Hovered: the text at full opacity, tick and dot.
    const box = await page.evaluate(() => {
      const rect = document.querySelector<HTMLElement>('[data-tick="12"]')!.getBoundingClientRect();
      return { x: rect.left + 8, y: rect.top + rect.height / 2 };
    });
    await page.mouse.move(box.x, box.y);
    await page.waitForSelector('[data-tick="12"][data-tone="active"]');
    const hovered = await look(page, 12);
    expect(hovered.opacity).toBe(1);
    expect(hovered.dot?.opacity).toBe(1);
    expect(hovered.color).not.toBe(rest.color);
    expect(hovered.color.replace(/\s/g, "")).toBe(
      await page.evaluate((value) => {
        const probe = document.createElement("div");
        probe.style.color = value;
        document.body.append(probe);
        const color = getComputedStyle(probe).color;
        probe.remove();
        return color.replace(/\s/g, "");
      }, text),
    );
    await page.close();
  });

  test("the ticks come in on an eased curve with a bounded stagger down the rail", async () => {
    const page = await open({ hold: true });
    const entrance = await page.evaluate(() => {
      const bars = [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick .acpmux-minimap__bar")];
      return bars.map((bar) => {
        const animation = bar
          .getAnimations()
          .find((entry) => (entry as CSSAnimation).animationName === "acpmux-minimap-tick-in");
        if (!animation) return undefined;
        const timing = animation.effect!.getComputedTiming();
        const delay = Number(timing.delay);
        const duration = Number(timing.duration);
        // Halfway through its run: an eased curve is well past halfway there, a linear one at half.
        animation.currentTime = delay + duration / 2;
        const half = new DOMMatrixReadOnly(getComputedStyle(bar).transform).a;
        animation.currentTime = delay + duration;
        animation.finish();
        const end = new DOMMatrixReadOnly(getComputedStyle(bar).transform).a;
        return { delay, duration, easing: getComputedStyle(bar).animationTimingFunction, half: half / end };
      });
    });
    expect(entrance.length).toBe(18);
    for (const tick of entrance) {
      expect(tick).toBeDefined();
      expect(tick!.easing).not.toBe("linear");
      expect(tick!.duration).toBeGreaterThan(0);
      expect(tick!.half).toBeGreaterThan(0.7);
      // The whole rail is in under 200 ms.
      expect(tick!.delay + tick!.duration).toBeLessThanOrEqual(200);
    }
    const delays = entrance.map((tick) => tick!.delay);
    // Staggered top to bottom: never earlier than the row above, the last row later than the first.
    for (let index = 1; index < delays.length; index++)
      expect(delays[index]!).toBeGreaterThanOrEqual(delays[index - 1]!);
    expect(delays.at(-1)!).toBeGreaterThan(delays[0]!);
    expect(Math.max(...delays)).toBeLessThanOrEqual(80);
    await page.close();
  });

  for (const [name, options] of [
    ["the system's Reduce Motion", { reduce: true, hold: true }],
    ["the app's motion gate", { motion: "reduced", hold: true }],
  ] as const)
    test(`under ${name} the ticks do not animate in`, async () => {
      const page = await open(options);
      const running = await page.evaluate(
        () =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__bar, .acpmux-minimap__dot")].filter((node) =>
            node.getAnimations().some((entry) => (entry as CSSAnimation).animationName?.startsWith("acpmux-minimap-")),
          ).length,
      );
      expect(running).toBe(0);
      await page.close();
    });
});
