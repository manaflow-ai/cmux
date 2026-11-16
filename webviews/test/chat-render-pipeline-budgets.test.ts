// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// The chat render pipeline's budgets (cmuxterm-hq docs/design/chat-render-pipeline.md, its "Checks" section). Leo,
// 2026-11-16: "The rendering wants to recalculating stuff when the agent chat stream is going/ends, but text comes in
// pretty quickly, and stuff shifts at the bottom pretty frequently, and then there's a big wave of stuff that gets
// redrawn". The doc gives each stage of a streamed reply a scope: a streamed token restyles its own row (and the tail
// under it), never the list; the stream's end settles the tail, never the list; a typed key forces no style or layout
// pass from script. This file holds the code to those scopes in Chromium, from a trace of the real pane:
//
//   stream    a 700-turn chat streams a reply (`loadRun`, no scrolling, no tool calls). Every style pass
//             (UpdateLayoutTree) restyles at most ROW_SCOPE elements, and none restyles more than LIST_FRACTION of
//             the elements under the scroller (the mounted rows and their frame): that is "the list".
//   settle    the 1 s after the stream ends (the mock marks `acpmux-load-stream-end`): the same, at TAIL_SCOPE.
//   typing    30 keys typed into the composer while a reply streams. In the key's own tasks (each task that dispatched a
//             key or input event), script forces at most FORCED_PER_KEY style or
//             layout passes per key (a pass whose trace event carries a JS stack), not counting the test's own
//             driver (loadDebug.ts reads the scroller every frame to time it).
//
// It found, on feat-cmux-next 49d40100083: the scroll origin (conversation/scrollCoordinates.ts
// `retainScrollOrigin`) written as an inherited custom property on the scroller restyled every mounted element,
// 1,500-1,970 per write, several times a streamed token, and the read after it forced the layout at once.
// CHAT_RENDER_MEASURE=1 prints the numbers and asserts nothing (to calibrate the budgets on a runner).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

// Budgets, from one fleet Linux runner (cmux-ci run 43859823833), feat-cmux-next 49d40100083 against the same tree with
// cmux#44439: stream p95 1,296 -> 9 elements per pass (max 1,395 -> 274, a share of 1.5 -> 0.3); settle max 178 both;
// forced passes in a key's tasks 1.1 per key both (the composer's own fieldGrowth.ts follow, one element), none from
// transcript code.
/** p95 elements one style pass may restyle while a reply streams: the streaming row's subtree and the line under it. */
export const ROW_SCOPE = 100;
/** The largest pass in the second after the stream ends: the turn's own rows fold and settle, nothing above them. */
export const TAIL_SCOPE = 600;
/** No pass may restyle more than this share of the elements under the scroller: a pass that does restyled the list. */
export const LIST_FRACTION = 0.5;
/** Style or layout passes script may force per typed key in the key's own tasks while a reply streams. */
export const FORCED_PER_KEY = 1.5;
/** Transcript code: none of its forced passes may run in a key's task (the doc's stage 7). */
const TRANSCRIPT =
  /VirtualTranscript|turnEndFold|Thinking\.tsx|scrollCoordinates|RevealedMarkdown|revealedMarkdownModel|tailGlide|pinnedLiveLine/;

const MEASURE = process.env.CHAT_RENDER_MEASURE === "1";
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const CATEGORIES = [
  "toplevel",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-devtools.timeline.stack",
  "blink.user_timing",
];
/** The test's own driver: its per-frame reads of the scroller are the harness's, not the pane's. */
const HARNESS = /loadDebug|debug\.ts|playwright|__puppeteer|pptr:/;

type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  pid: number;
  tid: number;
  args?: Record<string, any>;
};
type Pass = { kind: "style" | "layout"; ts: number; elements: number; stack: string | undefined };

/** Style and layout passes on the renderer's main thread, each with its element count and, when script forced it,
 * the top frames of the stack that did. */
export function passes(events: TraceEvent[]): Pass[] {
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const stackOf = (frames: unknown): string | undefined =>
    Array.isArray(frames) && frames.length
      ? frames
          .slice(0, 6)
          .map(
            (f: any) =>
              `${f.functionName || "(anon)"}@${
                String(f.url ?? "")
                  .split("/")
                  .pop()
                  ?.split("?")[0]
              }:${f.lineNumber}`,
          )
          .join(" < ")
      : undefined;
  const out: Pass[] = [];
  const open = new Map<string, TraceEvent>();
  for (const e of events.filter((each) => mains.has(`${each.pid}:${each.tid}`)).sort((a, b) => a.ts - b.ts)) {
    if (e.name !== "UpdateLayoutTree" && e.name !== "Layout") continue;
    const kind = e.name === "Layout" ? "layout" : "style";
    const key = `${e.name}:${e.tid}`;
    const finish = (begin: TraceEvent, end: TraceEvent) =>
      out.push({
        kind,
        ts: begin.ts,
        elements:
          kind === "style"
            ? Number(end.args?.elementCount ?? begin.args?.elementCount ?? end.args?.data?.elementCount ?? 0)
            : Number(begin.args?.beginData?.dirtyObjects ?? 0),
        stack: stackOf(begin.args?.beginData?.stackTrace),
      });
    if (e.ph === "X") finish(e, e);
    else if (e.ph === "B") open.set(key, e);
    else if (e.ph === "E") {
      const begin = open.get(key);
      open.delete(key);
      if (begin) finish(begin, e);
    }
  }
  return out;
}

const KEY_EVENTS = new Set(["keydown", "keypress", "beforeinput", "input", "keyup"]);

/** [start, end] in trace µs of each renderer main-thread task that dispatched a key or input event. */
export function keyTaskRanges(events: TraceEvent[]): [number, number][] {
  const mains = new Set(
    events
      .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
      .map((e) => `${e.pid}:${e.tid}`),
  );
  const onMain = (e: TraceEvent) => mains.has(`${e.pid}:${e.tid}`);
  const tasks = events
    .filter((e) => onMain(e) && e.name === "RunTask" && e.ph === "X" && e.dur !== undefined)
    .map((e) => [e.ts, e.ts + e.dur!] as [number, number]);
  const dispatches = events.filter(
    (e) => onMain(e) && e.name === "EventDispatch" && KEY_EVENTS.has(String(e.args?.data?.type)),
  );
  const out = new Map<number, [number, number]>();
  for (const d of dispatches) {
    const task = tasks.find(([start, end]) => d.ts >= start && d.ts <= end);
    if (task) out.set(task[0], task);
  }
  return [...out.values()];
}

function markAt(events: TraceEvent[], name: string): number | undefined {
  return events.find((e) => e.name === name)?.ts;
}

const percentile = (values: number[], q: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};

function summary(list: Pass[], scrollElements: number) {
  const styles = list.filter((p) => p.kind === "style");
  const counts = styles.map((p) => p.elements);
  const biggest = [...styles].sort((a, b) => b.elements - a.elements).slice(0, 3);
  return {
    styles: styles.length,
    elements: counts.reduce((a, b) => a + b, 0),
    p95: percentile(counts, 0.95),
    max: Math.max(0, ...counts),
    listShare: scrollElements ? Math.round((Math.max(0, ...counts) / scrollElements) * 100) / 100 : 0,
    biggest: biggest.map((p) => `${p.elements}${p.stack ? ` forced by ${p.stack}` : " (frame)"}`),
  };
}

async function trace(browser: Browser, page: Page, run: () => Promise<unknown>): Promise<TraceEvent[]> {
  await browser.startTracing(page, { categories: CATEGORIES });
  await run();
  return (JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: TraceEvent[] }).traceEvents;
}

await requireBrowserLane("chat-render-pipeline-budgets.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function openChat() {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(700))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
    const scrollElements = await page.evaluate(() => document.querySelectorAll(".acpmux-scroll *").length);
    return { page, scrollElements };
  }

  describe("chat render pipeline budgets (chromium)", () => {
    test("a streamed token restyles its row, the stream's end its tail, never the list", async () => {
      const { page, scrollElements } = await openChat();
      let run: Record<string, any> = {};
      const events = await trace(browser!, page, async () => {
        run = (await page.evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadRun({
            seconds: 3,
            chunk_chars: 24,
            chunk_ms: 16,
            tool_every: 0,
            scroll_speed: 0,
          }),
        )) as Record<string, any>;
        // The settle window: the second after the stream's end.
        await page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 1000)));
      });
      await page.close();
      expect(run.error).toBeUndefined();
      const all = passes(events);
      const end = markAt(events, "acpmux-load-stream-end");
      expect(end).toBeDefined();
      const stream = summary(
        all.filter((p) => p.ts < end!),
        scrollElements,
      );
      const settle = summary(
        all.filter((p) => p.ts >= end! && p.ts < end! + 1_000_000),
        scrollElements,
      );
      const deltas = Number(run.deltas ?? 0);
      const report = {
        scrollElements,
        deltas,
        stream: { ...stream, elementsPerDelta: deltas ? Math.round(stream.elements / deltas) : null },
        settle,
      };
      console.log(`CHAT-RENDER-BUDGETS stream ${JSON.stringify(report)}`);
      if (MEASURE) return;
      expect(deltas).toBeGreaterThan(20);
      expect(
        stream.p95,
        `p95 elements per style pass while streaming (${stream.biggest.join("; ")})`,
      ).toBeLessThanOrEqual(ROW_SCOPE);
      expect(
        stream.listShare,
        `largest restyle while streaming, share of the transcript (${stream.biggest.join("; ")})`,
      ).toBeLessThan(LIST_FRACTION);
      expect(settle.max, `largest restyle as the stream settles (${settle.biggest.join("; ")})`).toBeLessThanOrEqual(
        TAIL_SCOPE,
      );
      expect(settle.listShare, `largest restyle as the stream settles, share of the transcript`).toBeLessThan(
        LIST_FRACTION,
      );
    });

    test("a key typed while a reply streams forces no style or layout from script", async () => {
      const { page, scrollElements } = await openChat();
      await page.locator(PROMPT).first().click();
      const KEYS = 30;
      const events = await trace(browser!, page, async () => {
        const streaming = page.evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 4, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
        );
        // fixed-wait: the keys go in at a fast typist's pace, after the stream has started.
        await page.waitForTimeout(300);
        for (let i = 0; i < KEYS; i += 1) {
          await page.keyboard.press("abcdefghijklmnopqrstuvwxyz"[i % 26]!);
          // fixed-wait: the gap between keys is the measured pace.
          await page.waitForTimeout(60);
        }
        await streaming;
      });
      await page.close();
      const all = passes(events);
      const forcedAll = all.filter((p) => p.stack && !HARNESS.test(p.stack));
      // The key's own tasks: each main-thread task (toplevel RunTask) that dispatched a key or input event. A forced
      // pass in one of them is a pass the key waited on; the stream's own forced passes run in other tasks and are
      // reported (streamForced), not budgeted here.
      const keyTasks = keyTaskRanges(events);
      const inKey = (p: Pass) => keyTasks.some(([start, end]) => p.ts >= start && p.ts <= end);
      const forced = forcedAll.filter(inKey);
      const bySite = new Map<string, number>();
      for (const p of forced) {
        const site = `${p.kind} ${p.stack!.split(" < ").slice(0, 2).join(" < ")}`;
        bySite.set(site, (bySite.get(site) ?? 0) + 1);
      }
      const keydowns = events.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "keydown").length;
      const report = {
        scrollElements,
        keys: KEYS,
        keydowns,
        keyTasks: keyTasks.length,
        forced: forced.length,
        forcedPerKey: Math.round((forced.length / KEYS) * 100) / 100,
        forcedElements: forced.reduce((sum, p) => sum + (p.kind === "style" ? p.elements : 0), 0),
        sites: [...bySite].sort((a, b) => b[1] - a[1]).slice(0, 8),
        streamForced: forcedAll.length - forced.length,
        typing: summary(all, scrollElements),
      };
      console.log(`CHAT-RENDER-BUDGETS typing ${JSON.stringify(report)}`);
      if (MEASURE) return;
      expect(keydowns).toBeGreaterThanOrEqual(KEYS);
      expect(keyTasks.length).toBeGreaterThanOrEqual(KEYS);
      expect(
        report.forcedPerKey,
        `forced style/layout passes per key, by site: ${JSON.stringify(report.sites)}`,
      ).toBeLessThanOrEqual(FORCED_PER_KEY);
      const transcriptForced = forced.filter((p) => TRANSCRIPT.test(p.stack!));
      expect(
        transcriptForced.map((p) => `${p.kind} ${p.stack}`),
        "transcript code forced style or layout in a key's task",
      ).toEqual([]);
      expect(
        report.typing.listShare,
        `largest restyle while typing under a stream (${report.typing.biggest.join("; ")})`,
      ).toBeLessThan(LIST_FRACTION);
    });
  });
});
