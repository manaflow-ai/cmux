// The composer holds still while a turn runs (hq#1957: Leo saw heavy layout shift in the composer
// while a subagent ran). The gallery's `agent-pane.composer-turn-cycle` entry opens idle on a
// chat's first turn, before the agent has reported any context usage; the test then delivers the
// cycle's snapshots through the pane's bridge, as the app's arrive: running, one then three
// subagents, a subagent's permission ask, a queued prompt, finished. Across the cycle the prompt,
// the controls row, the footer and every control keep their boxes (within 0.5 px); the ask and the
// queue grow upward over the transcript. The draft is empty, so the idle and finished phases draw
// no Send (Claude desktop's box: no Send until there is a draft, Leo 2026-10-20): the mic holds the
// right edge throughout, Stop comes in before it while the turn runs and keeps one box, and the
// prompt keeps its left, top and height while its column gives Stop room. Typing while the turn
// runs (↵ joins Stop) moves neither the mic nor Stop. In every phase the row shows no context ring
// or spinner (the running state is Stop, nothing else) and one lock at most (hq#1957 item 15 compact
// row). The quiet row under the box (ComposerFoot.tsx) ends on the context ring, which holds its
// place from the first frame, so the first usage report moves nothing.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { TURN_CYCLE } from "../src/agent-session/acpmux/composerTurnCycle.gallery";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-turn-cycle", { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-turn-cycle", { browser, params: { variant: "idle" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const CONTROLS: Record<string, string> = {
    box: ".acpmux-composer-box",
    prompt: ".acpmux-composer-prompt",
    // The box's own row draws no box of its own (display: contents): + and the mic stand for it.
    footer: ".acpmux-composer-context",
    plus: ".acpmux-composer-plus .acpmux-picker-button",
    model: ".acpmux-model .acpmux-picker-button",
    // The model button's own effort label (Leo 2026-10-20: one button, no effort chip).
    effort: ".acpmux-model .acpmux-model-detail",
    access: ".acpmux-access-trigger",
    mic: ".acpmux-mic",
    // Stop while the turn runs; an idle row with an empty draft has none (no Send until there is a draft).
    "send or stop": ".acpmux-send",
    "context ring": ".acpmux-composer-foot .acpmux-context-ring",
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
      // Both rows: the box's own (+, the mic, Send or Stop) and, with the split, the quiet row under
      // it that holds the chips (ComposerFoot). The quiet row's one context ring is its own and holds
      // its place; nothing else rings or spins in either.
      const rows = [...document.querySelectorAll(".acpmux-composer-bar")];
      const out: string[] = [];
      if (!rows.some((row) => row.querySelector(".acpmux-access-trigger, .acpmux-model")))
        out.push("no row holds the chips");
      for (const row of rows) {
        const own = row.classList.contains("acpmux-composer-foot")
          ? ":not(.acpmux-context):not(.acpmux-context-ring)"
          : "";
        for (const element of row.querySelectorAll(
          `.acpmux-context${own}, .acpmux-context-ring${own}, [role="progressbar"], [class*="spinner"], [class*="-ring"]${own}`,
        ))
          out.push(`a ring or spinner (${element.className.toString() || element.tagName})`);
      }
      const locks = rows.reduce((sum, row) => sum + row.querySelectorAll('svg path[d^="M5.5 7V5.6"]').length, 0);
      if (locks > 1) out.push(`${locks} locks`);
      if (rows.some((row) => row.querySelector(".acpmux-permission-status"))) out.push("the granted-status chip");
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
    await page.locator(".acpmux-model .acpmux-model-detail:visible").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  for (const width of [420, 720, 1100]) {
    test(`at ${width} px nothing in the composer moves through a running turn`, async () => {
      const page = await open(width, TURN_CYCLE[0]!.name);
      const start = await boxes(page);
      const problems: string[] = (await calm(page)).map((problem) => `${TURN_CYCLE[0]!.name}: ${problem}`);
      // An empty draft at rest draws no Send; Stop's box is held to the first running phase's.
      if (start["send or stop"] !== "missing") problems.push(`${TURN_CYCLE[0]!.name}: Send shows with no draft`);
      let firstStop: number[] | "missing" | undefined;
      for (const { name, snapshot } of TURN_CYCLE.slice(1)) {
        await page.evaluate(
          (next) =>
            (window as unknown as { cmuxAcpmuxBridge: { receive(s: unknown): void } }).cmuxAcpmuxBridge.receive(next),
          snapshot,
        );
        await page.waitForFunction(
          (working) => (document.querySelector(".acpmux-cancel") !== null) === working,
          snapshot.isWorking,
        );
        // Two frames: the pane renders the snapshot, then any effect it lays out from.
        await page.evaluate(
          () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        );
        const now = await boxes(page);
        if (snapshot.isWorking) firstStop ??= now["send or stop"];
        const expected = { ...start, "send or stop": snapshot.isWorking ? firstStop! : start["send or stop"] };
        // While Stop shows, the prompt's column narrows by its width: the prompt keeps its left, top and height.
        const prompt = (all: typeof now) => {
          const box = all.prompt!;
          return { ...all, prompt: box === "missing" ? box : [box[0]!, box[1]!, box[3]!] };
        };
        problems.push(...moved(prompt(expected), prompt(now)).map((problem) => `${name}: ${problem}`));
        if (snapshot.isWorking && now["send or stop"] === "missing") problems.push(`${name}: no Stop`);
        problems.push(...(await calm(page)).map((problem) => `${name}: ${problem}`));
      }
      await page.close();
      expect(problems).toEqual([]);
    });

    test(`at ${width} px typing while the turn runs moves nothing: Stop's slot turns into Send`, async () => {
      const page = await open(width, "subagents-three");
      const before = await boxes(page);
      await page.click("[contenteditable='true']");
      await page.keyboard.type("x");
      // One send control (Leo 2026-10-31: "THE F***ING TWO SEND BUTTONS"): the first letter turns
      // Stop into Send in the same slot, so no control and not the prompt's column moves.
      await page.locator(".acpmux-composer-box .acpmux-send:not(.acpmux-cancel)").waitFor();
      const after = await boxes(page);
      await page.close();
      const fixed = Object.keys(CONTROLS);
      // The prompt keeps its place and height (its left, top and height), and every control its box.
      const pick = (all: typeof before) =>
        Object.fromEntries(
          fixed.map((name) => {
            const box = all[name]!;
            return [name, name === "prompt" && box !== "missing" ? [box[0]!, box[1]!, box[3]!] : box];
          }),
        );
      expect(moved(pick(before), pick(after))).toEqual([]);
    });
  }
});
