// Leo, 2026-11-10, about the agent chat: "The scroll rail isn't working right now. ... I don't know
// where my last chat just went." A long chat opens on its last page: the rail draws every prompt
// from the snapshot's count (pending ticks above the held ones), and older history pages in on
// demand. Clicking and dragging the rail must keep moving the transcript to the prompt under the
// pointer while those pages arrive, the lit band must follow, and the last tick must bring the
// reader back to the end of the chat. Each scenario is one way the rail is used: with and without
// the prompt index, while a reply streams, filtered to the person's own prompts, and on the
// Messages page (Home, Chief, a chat set to Messages).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LANDING_OFFSET } from "../src/agent-session/acpmux/threadMinimap/model";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Scenario = {
  name: string;
  /// The chat's prompt index answers a pending tick (`loadPromptIndex`), else history pages in.
  promptIndex: boolean;
  /// A reply streams into the last turn the whole time the rail is used.
  stream?: boolean;
  /// Every third prompt is another agent's message, and the rail is filtered to the person's own.
  mine?: boolean;
  /// The rows as the Messages page draws them (thread-minimap.harness.tsx `?presentation=messages`).
  messages?: boolean;
};

const SCENARIOS: Scenario[] = [
  { name: "no prompt index", promptIndex: false },
  { name: "with the prompt index", promptIndex: true },
  { name: "while a reply streams", promptIndex: true, stream: true },
  { name: "filtered to my own prompts", promptIndex: true, mine: true },
  { name: "on the Messages page", promptIndex: true, messages: true },
];

await requireBrowserLane("thread-minimap-paged-rail.test.ts", async () => {
  setDefaultTimeout(180_000);
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

  const TURNS = 300;
  const PAGE = 40;
  const incoming = (index: number) => index % 3 === 1;
  // Rows numbered as acpmux numbers its records, so a prompt's id is `user-<seq>`.
  const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
  const prompt = (index: number, mixed: boolean): AcpmuxRow =>
    mixed && incoming(index)
      ? {
          ...row(`user-${index * 3 + 1}`, "user", `Ask ${index}`),
          incoming: {
            kind: "message",
            message: { name: "other-agent", sessionId: "other-agent", text: `Ask ${index}`, raw: `Ask ${index}` },
          },
        }
      : row(`user-${index * 3 + 1}`, "user", `Ask ${index}`);
  const turn = (index: number, mixed: boolean) => [
    prompt(index, mixed),
    row(`assistant-${index * 3 + 2}`, "assistant", `Answer ${index}. A long answer keeps the row measurable.`),
    { ...row(`summary-${index * 3 + 3}`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ];

  /// Opens the chat on its last page with the snapshot's prompt count; older pages come in on
  /// demand (the transcript's onLoadOlder near the top, the rail's loadThrough for a prompt).
  async function open(page: Page, scenario: Scenario) {
    const { port } = vite!.httpServer!.address() as { port: number };
    const query = scenario.messages ? "?presentation=messages" : "";
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html${query}`);
    await page.waitForFunction(() => "__showRows" in window && "__setOlderPage" in window);
    const rows = Array.from({ length: TURNS }, (_, index) => turn(index, scenario.mine === true)).flat();
    await page.evaluate(
      ({ rows, turns, size, promptIndex, stream }) => {
        const state = window as any;
        state.__start = turns - size;
        state.__pages = 0;
        state.__earlier = undefined;
        state.__streamed = "";
        const current = () => {
          const held = rows.slice(state.__start * 3);
          if (!state.__streamed) return held;
          // The last turn's reply as it streams: a new row each token, as the pane's snapshot has it.
          const last = held.length - 2;
          return [...held.slice(0, last), { ...held[last], text: `${held[last].text} ${state.__streamed}` }, held.at(-1)];
        };
        const show = () => {
          const extra: Record<string, unknown> = { promptCount: turns };
          if (state.__earlier) extra.earlier = state.__earlier.slice(0, state.__start);
          state.__showRows(current(), extra);
        };
        state.__show = show;
        const older = () =>
          new Promise<boolean>((resolve) =>
            setTimeout(() => {
              if (state.__start === 0) return resolve(false);
              state.__start = Math.max(0, state.__start - size);
              state.__pages++;
              show();
              resolve(true);
            }, 40),
          );
        state.__setOlderPage(async () => {
          await older();
        });
        state.__setLoadThrough(async (seq: number) => {
          while ((state.__start as number) * 3 + 1 > seq) if (!(await older())) return false;
          return true;
        });
        if (promptIndex)
          state.__setPromptIndex(
            () =>
              new Promise<boolean>((resolve) =>
                setTimeout(() => {
                  // The index names every prompt: the ones not held come as `earlier`.
                  state.__earlier = Array.from({ length: turns }, (_, index) => rows[index * 3]);
                  show();
                  resolve(true);
                }, 40),
              ),
          );
        show();
        if (stream) {
          let token = 0;
          state.__stream = setInterval(() => {
            token++;
            state.__streamed += ` token${token}`;
            if (token % 12 === 0) state.__streamed += "\n\n";
            show();
          }, 50);
        }
      },
      { rows, turns: TURNS, size: PAGE, promptIndex: scenario.promptIndex, stream: scenario.stream === true },
    );
    await page.waitForSelector(".acpmux-minimap__tick");
    await settle(page);
  }

  async function settle(page: Page, ms = 600) {
    await page.waitForTimeout(ms);
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  }

  /// Filters the rail to the person's own prompts from its right-click menu.
  async function filterMine(page: Page) {
    // As thread-minimap-filter-fades.test.tsx opens the menu: a contextmenu on a tick.
    await page.evaluate(() => {
      const tick = document.querySelector<HTMLElement>(".acpmux-minimap__tick")!;
      const box = tick.getBoundingClientRect();
      tick.dispatchEvent(
        new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left + 6, clientY: box.top + 5 }),
      );
    });
    await page.waitForSelector('[role="menuitemcheckbox"]');
    await page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>('[role="menuitemcheckbox"]')]
        // All, mine, agents (ThreadMinimap `RAIL_FILTER_LABEL`); the harness draws catalog keys.
        .at(1)!
        .click(),
    );
    await settle(page);
  }

  /// The turn tick `index` stands for: with the chat's prompt count every prompt keeps its row (pending
  /// ones included); filtered to the person's own, the kept prompts from the loaded start, in order.
  const turnOfTick = (scenario: Scenario, index: number, start: number) => {
    if (!scenario.mine) return index;
    const kept: number[] = [];
    for (let at = start; at < TURNS; at++) if (!incoming(at)) kept.push(at);
    return kept[index];
  };
  const loadedStart = (page: Page) => page.evaluate(() => (window as any).__start as number);

  /// The rail's tick count, and the prompt a tick names now (a pending tick names none until the
  /// index or a page does).
  const tickCount = (page: Page) =>
    page.evaluate(() => Number(document.querySelector(".acpmux-minimap__entry")?.getAttribute("aria-setsize") ?? 0));
  async function namedBy(page: Page, scenario: Scenario, index: number) {
    return turnOfTick(scenario, index, await loadedStart(page));
  }

  /// Where prompt `turn`'s row is below the scroller's top, if mounted, the prompts the lit ticks
  /// name, and whether the view is at the end of the chat.
  async function where(page: Page, scenario: Scenario, turnIndex: number | undefined) {
    const start = await loadedStart(page);
    const spot = await page.evaluate((id) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const node =
        id === undefined
          ? undefined
          : [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => row.dataset.rowId === id);
      const litTicks = [...document.querySelectorAll<HTMLElement>('.acpmux-minimap__tick[aria-current="true"]')];
      const lit = litTicks.map((tick) => Number(tick.dataset.tick));
      return {
        top: node ? node.getBoundingClientRect().top - view.top : undefined,
        lit,
        label: litTicks[0]?.getAttribute("aria-label"),
        atEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop <= 2,
        scrollTop: scroller.scrollTop,
        start: (window as any).__start as number,
      };
    }, turnIndex === undefined ? undefined : `user-${turnIndex * 3 + 1}`);
    // The lit ticks as the turns they stand for.
    return { ...spot, lit: spot.lit.map((index) => turnOfTick(scenario, index, start)).filter((at): at is number => at !== undefined) };
  }

  /// A tick's center on screen, scrolling the rail's own list to it first (as a wheel over it would).
  async function tickPoint(page: Page, index: number) {
    await page.evaluate((at) => {
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      const want = at * 10 - list.clientHeight / 2;
      if (list.scrollHeight > list.clientHeight + 1 && Math.abs(list.scrollTop - want) > list.clientHeight / 2 - 20) {
        list.dispatchEvent(new WheelEvent("wheel", { deltaY: want - list.scrollTop, bubbles: true }));
        list.scrollTop = Math.max(0, want);
      }
    }, index);
    await page.waitForSelector(`[data-tick="${index}"]`);
    return page.evaluate((at) => {
      const box = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
      return { x: box.left + 6, y: box.top + box.height / 2 };
    }, index);
  }

  /// The tick under a point on the rail's list, as the rail's scrub reads it, and the prompt it names.
  async function tickUnder(page: Page, y: number) {
    return page.evaluate((clientY) => {
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      return Math.floor((clientY - list.getBoundingClientRect().top + list.scrollTop) / 10);
    }, y);
  }

  async function click(page: Page, index: number) {
    const point = await tickPoint(page, index);
    await page.mouse.click(point.x, point.y);
  }

  /// Drags on the rail from tick `from` by `rows` rows; returns the prompt under the pointer at release.
  async function drag(page: Page, scenario: Scenario, from: number, rows: number) {
    const start = await tickPoint(page, from);
    const steps = Math.max(8, Math.abs(rows));
    await page.mouse.move(start.x, start.y);
    await page.mouse.down();
    for (let step = 1; step <= steps; step++) {
      await page.mouse.move(start.x, start.y + (rows * 10 * step) / steps);
      await page.waitForTimeout(16);
    }
    const index = await tickUnder(page, start.y + rows * 10);
    const turnIndex = turnOfTick(scenario, index, await loadedStart(page));
    await page.mouse.up();
    return { index, turnIndex };
  }

  const landed = (spot: { top?: number }) => spot.top !== undefined && Math.abs(spot.top - LANDING_OFFSET) <= 4;
  /// A jump landed its prompt on the landing line, and the band lights the prompt's tick.
  const holds = (spot: { top?: number; lit: number[] }, turnIndex: number | undefined) =>
    turnIndex !== undefined && landed(spot) && spot.lit.includes(turnIndex);

  for (const scenario of SCENARIOS)
    describe(`the prompt rail over a paged long chat (Chromium, ${scenario.name})`, () => {
      test("click, drag and the last tick keep moving the transcript while older pages arrive", async () => {
        const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
        await open(page, scenario);
        const report: Record<string, unknown> = { scenario: scenario.name };
        const results: Record<string, boolean> = {};
        try {
          if (scenario.mine) await filterMine(page);
          const count = await tickCount(page);
          report.ticks = count;
          if (!scenario.mine) expect(count).toBe(TURNS);

          // 1. A click on a held prompt's tick lands it.
          const held = count - 10;
          const heldPrompt = await namedBy(page, scenario, held);
          await click(page, held);
          await settle(page);
          const clickHeld = await where(page, scenario, heldPrompt);
          report.clickHeld = { ...clickHeld, heldPrompt };
          results.clickHeld = holds(clickHeld, heldPrompt);

          // 2. A drag from that tick up: across the pending ticks above the held page (or, filtered,
          // across held ones while the view pages in): each row it crosses is the transcript's, and
          // where it ends is where the reader is.
          const up = await drag(page, scenario, held, scenario.mine ? -15 : -(PAGE + 5));
          await settle(page, 1_500);
          const draggedPrompt = up.turnIndex;
          const dragged = await where(page, scenario, draggedPrompt);
          report.dragged = { ...dragged, under: up, draggedPrompt };
          results.dragged = holds(dragged, draggedPrompt);

          // 3. A click on a far tick reads its history in and lands it.
          const far = scenario.mine ? 2 : 60;
          const farPrompt = await namedBy(page, scenario, far);
          await click(page, far);
          await settle(page, 2_000);
          const clickFar = await where(page, scenario, farPrompt);
          report.clickFar = { ...clickFar, farPrompt };
          results.clickFar = holds(clickFar, farPrompt);

          // 4. The last tick brings the reader back to the end of the chat, its prompt lit. The last
          // prompt sits at the chat's end, so the view stops at the bottom, not on the landing line.
          const lastIndex = (await tickCount(page)) - 1;
          const lastPrompt = await namedBy(page, scenario, lastIndex);
          await click(page, lastIndex);
          await settle(page, 1_000);
          const last = await where(page, scenario, lastPrompt);
          report.last = { ...last, lastPrompt };
          results.last = last.atEnd && lastPrompt !== undefined && last.lit.includes(lastPrompt);

          // 5. A drag down from far up, across held rows after the history read in.
          const downFrom = scenario.mine ? 10 : 80;
          const down = await drag(page, scenario, downFrom, 20);
          await settle(page, 1_000);
          const downPrompt = down.turnIndex;
          const draggedDown = await where(page, scenario, downPrompt);
          report.draggedDown = { ...draggedDown, under: down, downPrompt };
          results.draggedDown = holds(draggedDown, downPrompt);

          expect(results).toEqual({ clickHeld: true, dragged: true, clickFar: true, last: true, draggedDown: true });
        } finally {
          console.log(`RAILREPORT ${JSON.stringify({ ...report, results })}`);
          await page.evaluate(() => clearInterval((window as any).__stream)).catch(() => undefined);
          await page.close();
        }
      });
    });
});
