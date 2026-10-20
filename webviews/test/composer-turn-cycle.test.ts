// The composer holds still while a turn runs (hq#1957: Leo saw heavy layout shift in the composer
// while a subagent ran). The gallery's `agent-pane.composer-turn-cycle` entry opens idle on a
// chat's first turn, before the agent has reported any context usage; the test then delivers the
// cycle's snapshots through the pane's bridge, as the app's arrive: running, one then three
// subagents, a subagent's permission ask, a queued prompt, finished. Across the cycle the prompt,
// the controls row, the footer and every control keep their boxes (within 0.5 px); the ask and the
// queue grow upward over the transcript. Typing while the turn runs (Stop becomes Steer and Send)
// moves neither the mic nor Send. In every phase the row shows no context ring or spinner (the
// running state is Send turned Stop, nothing else) and one lock at most (hq#1957 item 15 compact
// row).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { TURN_CYCLE } from "../src/agent-session/acpmux/composerTurnCycle.gallery";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-turn-cycle.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-turn-cycle: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer turn cycle", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer-turn-cycle&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 720, height: 520 } });
    await warm.goto(stageURL("idle"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const CONTROLS: Record<string, string> = {
    box: ".acpmux-composer-box",
    prompt: ".acpmux-composer-prompt",
    bar: ".acpmux-composer-bar",
    footer: ".acpmux-composer-context",
    plus: ".acpmux-composer-plus .acpmux-picker-button",
    model: ".acpmux-model .acpmux-picker-button",
    effort: ".acpmux-effort .acpmux-picker-button",
    access: ".acpmux-access-trigger",
    mic: ".acpmux-mic",
    "send or stop": ".acpmux-send",
  };

  /** Each control's box, or "missing". */
  const boxes = (page: Page) =>
    page.evaluate((controls) => {
      const out: Record<string, number[] | "missing"> = {};
      for (const [name, selector] of Object.entries(controls)) {
        const element = document.querySelector(selector);
        const rect = element?.getBoundingClientRect();
        out[name] = rect && rect.width > 0 ? [rect.left, rect.top, rect.width, rect.height] : "missing";
      }
      return out;
    }, CONTROLS);

  /** What the row should not show: a ring or spinner, more than one lock, the granted-status chip. */
  const calm = (page: Page) =>
    page.evaluate(() => {
      const bar = document.querySelector(".acpmux-composer-bar")!;
      const out: string[] = [];
      for (const element of bar.querySelectorAll(
        '.acpmux-context, .acpmux-context-ring, [role="progressbar"], [class*="spinner"], [class*="-ring"]',
      ))
        out.push(`a ring or spinner (${element.className.toString() || element.tagName})`);
      const locks = bar.querySelectorAll('svg path[d^="M5.5 7V5.6"]').length;
      if (locks > 1) out.push(`${locks} locks`);
      if (bar.querySelector(".acpmux-permission-status")) out.push("the granted-status chip");
      return out;
    });

  /** What moved, resized, came or went between two measurements. */
  const moved = (before: Record<string, number[] | "missing">, after: Record<string, number[] | "missing">) =>
    Object.keys(before).flatMap((name) => {
      const [a, b] = [before[name]!, after[name]!];
      if (a === "missing" || b === "missing")
        return a === b ? [] : [`${name} ${a === "missing" ? "appeared" : "went"}`];
      return a.some((value, index) => Math.abs(value - b[index]!) > 0.5)
        ? [`${name} ${a.map(Math.round).join(",")} -> ${b.map(Math.round).join(",")}`]
        : [];
    });

  const open = async (width: number, variant: string) => {
    const page = await browser!.newPage({ viewport: { width, height: 520 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-effort .acpmux-picker-button").waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  for (const width of [420, 720, 1100]) {
    test(`at ${width} px nothing in the composer moves through a running turn`, async () => {
      const page = await open(width, TURN_CYCLE[0]!.name);
      const start = await boxes(page);
      const problems: string[] = (await calm(page)).map((problem) => `${TURN_CYCLE[0]!.name}: ${problem}`);
      for (const { name, snapshot } of TURN_CYCLE.slice(1)) {
        await page.evaluate(
          (next) =>
            (window as unknown as { cmuxAcpmuxBridge: { receive(s: unknown): void } }).cmuxAcpmuxBridge.receive(next),
          snapshot,
        );
        await page.waitForFunction(
          (working) => document.querySelector(working ? ".acpmux-cancel" : ".acpmux-send:not(.acpmux-cancel)"),
          snapshot.isWorking,
        );
        // Two frames: the pane renders the snapshot, then any effect it lays out from.
        await page.evaluate(
          () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        );
        problems.push(...moved(start, await boxes(page)).map((problem) => `${name}: ${problem}`));
        problems.push(...(await calm(page)).map((problem) => `${name}: ${problem}`));
      }
      await page.close();
      expect(problems).toEqual([]);
    });

    test(`at ${width} px typing while the turn runs moves neither the mic nor Send`, async () => {
      const page = await open(width, "subagents-three");
      const before = await boxes(page);
      await page.click("[contenteditable='true']");
      await page.keyboard.type("x");
      await page.locator(".acpmux-steer").waitFor();
      const after = await boxes(page);
      await page.close();
      // A narrow row makes room for Steer from its left cluster (labels give way by priority).
      const fixed = width >= 720 ? Object.keys(CONTROLS) : ["prompt", "bar", "footer", "mic", "send or stop"];
      const pick = (all: typeof before) => Object.fromEntries(fixed.map((name) => [name, all[name]!]));
      expect(moved(pick(before), pick(after))).toEqual([]);
    });
  }
});
