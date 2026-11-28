// l10n-allow-file: benchmark output, not shipped UI.
// Which components one event renders in the agent pane, by name (bench/renderCounts.ts). Leo, 2026-11-18: "could
// you just draw the diff? I mean, isn't that what React is supposed to do? But we're, like, not doing it properly
// for some reason." An event should render what it changed and nothing else:
//   key      one composer keystroke (real key events, 80 ms apart): the composer only;
//   token    one streamed reply delta (`loadRun`, no tool calls, no scrolling): the streaming row only;
//   tool     one tool call added to a running turn, its call then its result (`loadTools`, no text): its row only;
//   switch   selecting the other open chat (`selectSession`), until the page has been still for 1 s;
//   show     the page hidden, then shown again (`visibilitychange`): nothing changed, so ideally 0;
//   resize   one 20 px width step of the pane, 12 steps: the rows whose wrap changed;
//   scroll   one 40 px wheel step up the transcript, 30 steps: the rows coming into view, never the composer;
//   hover    one pointer move down the transcript, 40 moves: the hovered row's actions, never the composer;
//   list.select / list.new   with LIST listed sessions (default 10,789, Leo's count, 2026-11-18): selecting a
//            listed chat and starting a new chat, the pane's side of the sidebar's selection and new workspace.
// The real pane (`?mock`: the real direct client against the in-page mock daemon), an unminified production build
// (React Compiler on, as it ships), so component names are real. Two light chats of TURNS turns each.
// Each row prints `RENDERS <scenario> ...` with the top components, then one summary table.
//   bun bench/render-counts.bench.ts [turns=300] [--list 10789] [--keys 20] [--tools 20] [--only key,token,...]
/// <reference types="bun" />
import path from "node:path";
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
import {
  addRenderCountProbe,
  formatRenderCounts,
  perEvent,
  renderCountProbeAttached,
  renderCountsReset,
  renderCountsTake,
  type RenderCounts,
} from "./renderCounts";
import { benchPositionals, requireProductionReact, installReactWatch } from "./support/benchPage";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const TURNS = Number(benchPositionals(argv.filter((arg, i) => !argv[i - 1]?.startsWith("--")))[0] ?? 300);
const LIST = Number(flag("--list") ?? 10_789);
const KEYS = Number(flag("--keys") ?? 20);
const TOOLS = Number(flag("--tools") ?? 20);
const ONLY = flag("--only")?.split(",");
const want = (name: string) => !ONLY || ONLY.includes(name);
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const webviews = path.resolve(import.meta.dir, "..");

type Row = { scenario: string; per: string; counts: RenderCounts; ms: number };
const rows: Row[] = [];
const record = (scenario: string, per: string, counts: RenderCounts, ms: number) => {
  rows.push({ scenario, per, counts, ms });
  console.log(formatRenderCounts(`${scenario} (per ${per})`, counts));
  // Every cause, packed into short lines: a CI log cuts a long line short and keeps only its last lines, and
  // the long tail is where a missing memo hides.
  const pack = (label: string, entries: [string, number][]) => {
    let line = "";
    for (const [name, count] of entries.sort((a, b) => b[1] - a[1])) {
      const item = `${name}=${Math.round(count * 100) / 100}`;
      if (line && line.length + item.length > 300) {
        console.log(`${label} ${scenario}: ${line}`);
        line = "";
      }
      line += (line ? " | " : "") + item;
    }
    if (line) console.log(`${label} ${scenario}: ${line}`);
  };
  pack("WHY", Object.entries(counts.why));
  pack("MOUNT", Object.entries(counts.mountsByComponent));
  pack("STARTS", Object.entries(counts.starts ?? {}));
};

/// Two frames and a task after them: whatever the event scheduled has committed.
const settle = (page: Page, ms = 0) =>
  page.evaluate(
    (wait) =>
      new Promise<void>((resolve) =>
        setTimeout(
          () =>
            requestAnimationFrame(() =>
              requestAnimationFrame(() => {
                const channel = new MessageChannel();
                channel.port1.onmessage = () => resolve();
                channel.port2.postMessage(0);
              }),
            ),
          wait,
        ),
      ),
    ms,
  );
const now = (page: Page) => page.evaluate(() => performance.now());

async function openPane(page: Page, port: number, list: number) {
  await page.addInitScript((count) => {
    const mock = globalThis as { cmuxAcpmuxMockListSize?: number; cmuxAcpmuxMockPaged?: boolean };
    mock.cmuxAcpmuxMockListSize = count;
    // The list in pages of the client's `limit`, as acpmux sends it (mock.ts `listPage`).
    mock.cmuxAcpmuxMockPaged = true;
  }, list);
  await addRenderCountProbe(page);
  await installReactWatch(page);
  page.on("pageerror", (error) => console.error(`bench page error: ${error.message}`));
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  await requireProductionReact(page, { dev: false });
  if (!(await renderCountProbeAttached(page))) throw new Error("react-dom did not register with the render probe");
}

async function seed(page: Page, turns: number): Promise<string> {
  const seeded = (await page.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
  return String(seeded.session);
}

const releases: (() => unknown)[] = [];
try {
  const port = await servePane(webviews, { unminified: true }, releases);
  const browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  console.log(`render-counts: ${TURNS} light turns per chat, ${LIST} listed sessions in the list arm`);

  {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    await openPane(page, port, 0);
    const a = await seed(page, TURNS);
    const b = await seed(page, TURNS);
    await settle(page, 1500); // fixed-wait: the open's read-ahead and fonts land first.

    if (want("key")) {
      await page.locator(PROMPT).first().click();
      for (const key of "warm") await page.keyboard.press(key);
      for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
      await settle(page, 500);
      await renderCountsReset(page);
      const t0 = await now(page);
      for (let i = 0; i < KEYS; i += 1) {
        await page.keyboard.press(String.fromCharCode(97 + (i % 26)));
        await settle(page, 60);
      }
      const ms = ((await now(page)) - t0) / KEYS;
      record("key", "key", perEvent(await renderCountsTake(page), KEYS), ms);
      for (let i = 0; i < KEYS; i += 1) await page.keyboard.press("Backspace");
      await settle(page, 300);
    }

    if (want("token")) {
      await renderCountsReset(page);
      const run = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 2, chunk_ms: 16, tool_every: 0, scroll_speed: 0 }),
      )) as Record<string, any>;
      if (run.error) throw new Error(`loadRun: ${run.error}`);
      const counts = await renderCountsTake(page);
      const deltas = Number(run.deltas ?? run.events ?? run.frames ?? 1);
      record("token", "delta", perEvent(counts, deltas), Number(run.work_ms?.p50 ?? 0));
      await settle(page, 1000);
    }

    if (want("tool")) {
      // The turn starts and its first calls land outside the window, so it counts only calls added to a running
      // turn: each a new row (its call, then 60 ms later its result), as a coordinator's chat gets them.
      const loadTools = (count: number, keepOpen: boolean) =>
        page.evaluate(
          ([n, open]) => (window as any).cmuxAcpmuxDebug.loadTools({ count: n, gap_ms: 60, keep_open: open }),
          [count, keepOpen] as const,
        ) as Promise<Record<string, any>>;
      const warm = await loadTools(2, true);
      if (warm.error) throw new Error(`loadTools: ${warm.error}`);
      await settle(page, 500);
      await renderCountsReset(page);
      const t0 = await now(page);
      const added = await loadTools(TOOLS, true);
      await settle(page, 300);
      const ms = ((await now(page)) - t0 - 300) / TOOLS;
      record("tool", "tool call", perEvent(await renderCountsTake(page), TOOLS), ms);
      await loadTools(0, false);
      if (added.tools !== TOOLS) throw new Error(`loadTools added ${added.tools} of ${TOOLS}`);
      await settle(page, 1000);
    }

    if (want("switch")) {
      for (const [label, target] of [
        ["switch", a],
        ["switch.back", b],
      ] as const) {
        await renderCountsReset(page);
        const t0 = await now(page);
        await page.evaluate((id) => (window as any).cmuxAcpmuxDebug.selectSession(id), target);
        await settle(page, 1000);
        record(label, "switch", await renderCountsTake(page), (await now(page)) - t0 - 1000);
      }
    }

    if (want("show")) {
      const setHidden = (hidden: boolean) =>
        page.evaluate((value) => {
          Object.defineProperty(document, "hidden", { configurable: true, get: () => value });
          Object.defineProperty(document, "visibilityState", {
            configurable: true,
            get: () => (value ? "hidden" : "visible"),
          });
          document.dispatchEvent(new Event("visibilitychange"));
        }, hidden);
      await setHidden(true);
      await settle(page, 500);
      await renderCountsReset(page);
      const t0 = await now(page);
      await setHidden(false);
      await settle(page, 1000);
      record("show", "show", await renderCountsTake(page), (await now(page)) - t0 - 1000);
    }

    if (want("resize")) {
      const steps = 12;
      await renderCountsReset(page);
      const t0 = await now(page);
      for (let i = 1; i <= steps; i += 1) {
        await page.setViewportSize({ width: 1200 - 20 * i, height: 800 });
        await settle(page);
      }
      const ms = ((await now(page)) - t0) / steps;
      record("resize", "20px step", perEvent(await renderCountsTake(page), steps), ms);
      await page.setViewportSize({ width: 1200, height: 800 });
      await settle(page, 500);
    }

    // Leo, 2026-11-08: the composer "re-renders on hover plus scroll". Neither should render the composer at all.
    if (want("scroll")) {
      const steps = 30;
      await page.locator(".acpmux-scroll").hover();
      await settle(page, 300);
      await renderCountsReset(page);
      const t0 = await now(page);
      for (let i = 0; i < steps; i += 1) {
        await page.mouse.wheel(0, -40);
        await settle(page);
      }
      const ms = ((await now(page)) - t0) / steps;
      record("scroll", "40px wheel", perEvent(await renderCountsTake(page), steps), ms);
      await settle(page, 500);
    }

    if (want("hover")) {
      const box = await page.locator(".acpmux-scroll").boundingBox();
      if (!box) throw new Error("hover: no transcript");
      const steps = 40;
      await page.mouse.move(box.x + box.width / 2, box.y + 10);
      await settle(page, 300);
      await renderCountsReset(page);
      const t0 = await now(page);
      for (let i = 1; i <= steps; i += 1) {
        await page.mouse.move(box.x + box.width / 2, box.y + 10 + ((box.height - 20) * i) / steps);
        await settle(page);
      }
      const ms = ((await now(page)) - t0) / steps;
      record("hover", "pointer move", perEvent(await renderCountsTake(page), steps), ms);
    }
    await context.close();
  }

  if (want("list") && LIST > 0) {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    await openPane(page, port, LIST);
    await seed(page, TURNS);
    await settle(page, 2000); // fixed-wait: the list's pages land first.
    await renderCountsReset(page);
    let t0 = await now(page);
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.selectSession("listed-7"));
    await settle(page, 1000);
    record("list.select", "select", await renderCountsTake(page), (await now(page)) - t0 - 1000);
    await renderCountsReset(page);
    t0 = await now(page);
    await page.evaluate(() => (window as any).cmuxAcpmuxActions["chat.new"]({ harness: "claude" }));
    await settle(page, 1000);
    record("list.new", "new chat", await renderCountsTake(page), (await now(page)) - t0 - 1000);
    await context.close();
  }

  console.log("scenario | per | renders | mounts | host | commits | ms");
  for (const row of rows)
    console.log(
      `${row.scenario} | ${row.per} | ${row.counts.renders} | ${row.counts.mounts} | ${row.counts.host} | ${row.counts.commits} | ${row.ms.toFixed(1)}`,
    );
  console.log(`RENDER-COUNTS-JSON ${JSON.stringify(rows)}`);
} finally {
  for (const release of releases.reverse()) await release();
}
