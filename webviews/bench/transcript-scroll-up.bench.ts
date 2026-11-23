// l10n-allow-file: bench output labels, not shipped UI.
// Scrolling up a long agent chat, as Leo did on 2026-11-11 ("scrolling up is slow and it layout shift and
// everythng lag"; "likewise the scrollign up thing, the thumb turns from a tiny thing that would imply a big
// chat to just a medium sized thumb at the top"). The real pane (its dev entry, test/support/papercutChat.ts)
// joins a stand-in acpmux holding the generated ordinary chat (bench/godFixture.ts `small` shape: tool runs,
// heavy edit and shell turns, a subagent chain, screenshots, code and lists) at TURNS turns. The chat opens on
// its tail and pages older history in as the reader wheels up, as acpmux serves a long chat. A precise wheel
// (support/upwardAnchorTrace.ts: a real WheelEvent through the pane's handlers, its default applied) moves the
// view up by uneven trackpad steps, one a frame, from the latest message to the first prompt. Every painted
// frame is read:
//   blank        frames whose view shows no row, or a band the rows leave uncovered (a missing row, a gap no
//                spacing token explains), or an edge gap past 8 px
//   drift        how far a row on screen moved beyond what the wheel asked (px; 0 means the row under the
//                pointer moved exactly with the wheel)
//   frame        intervals between painted frames while the wheel moves (ms, p50/p95/max)
//   long tasks   main-thread tasks over 50 ms (Chromium only: WebKit has no longtask entries)
//   thumb        the scrollbar thumb's size (viewport / content height) over the run: the largest change from
//                the first frame's, in percent, and frames whose thumb moved down while the reader went up
//                (the thumb must only go up while the wheel goes up)
// The pane is a production build (DEV=1: the dev server).
//   older pages  each older page the transcript asked for: ask to the first painted frame after it settled
//                whose content height changed (askToDrawn p50/p95/max), asks never drawn, and frames the
//                reader asked to go up while the view could not move (loadingFrames); each page on the wire
//                (ask to reply, its size). The stand-in serves the page size the pane asks for (SMALL_PAGES=1:
//                the attach's 160 records, as before)
//   TURNS=600 ENGINES=webkit,chromium STEP=1 bun bench/transcript-scroll-up.bench.ts
//   FIXTURE=flat ROWS=100000 MODE=wheel|fling|drag PAGES=24 ENGINES=chromium bun bench/transcript-scroll-up.bench.ts
//                (the 100k-row chat of chat-100k-flat.bench.ts, stopped after 24 older pages)
// STEP scales the wheel's steps (1: about 80 px a frame, a trackpad flick; 0.4 a reading scroll). Prints one
// summary line per engine and PERF_ROW lines; exits 1 when a goal is missed (0 blank frames, drift under 1 px,
// p95 frame under 16.7 ms, thumb size change under 5 %, thumb never moving down). Run it yourself; it is not a CI
// gate (written under the 2026-10-23 no-new-CI rule, since lifted):
// `cmux-ci test -- 'cd webviews && bun bench/transcript-scroll-up.bench.ts'`.
/// <reference types="bun" />
import { chromium, webkit } from "./browsers";
import type { Browser, BrowserType } from "playwright";
import { godLog } from "./godFixture";
import { papercutPane, type PapercutStep } from "../test/support/papercutChat";
import { traceUpwardAnchors } from "../test/support/upwardAnchorTrace";
import { perfRow } from "./perfRow";
import { reportOlderSplit, type CpuProfile } from "./olderPageSplit";

const TURNS = Number(process.env.TURNS ?? 600);
const STEP = Number(process.env.STEP ?? 1);
const ENGINES = (process.env.ENGINES ?? "webkit,chromium").split(",").filter(Boolean);
const MAX_ROUNDS = Number(process.env.ROUNDS ?? 400);
const FRAMES_PER_ROUND = 120;
const FRAME_BUDGET_MS = 1000 / 60;
/// MODE: wheel (a trackpad scroll, STEP-scaled), fling (each frame's wheel 1,500 to 3,000 px; FLING=1 too) or
/// drag (the scrollbar thumb dragged up: the offset moves 2,400 to 4,800 px a frame with no wheel event).
const MODE = process.env.MODE ?? (process.env.FLING === "1" ? "fling" : "wheel");
const FLING = MODE === "fling";
const DRAG = MODE === "drag";
/// LATENCY=ms: each older page lands that late, as from a remote or busy acpmux.
const LATENCY = Number(process.env.LATENCY ?? 0);
/// FIXTURE=flat ROWS=100000: the 100k-row chat of bench/chat-100k-flat.bench.ts (ROWS/2 turns of a question
/// and its answer) instead of the generated ordinary log at TURNS turns.
const FLAT = process.env.FIXTURE === "flat";
const ROWS = Number(process.env.ROWS ?? 100_000);
/// PAGES=N: stop once N older pages have been drawn (a 100k-row chat's top is thousands of screens up; the
/// per-page time is what has to stay flat). 0 runs to the first prompt.
const PAGES = Number(process.env.PAGES ?? 0);
/// SMALL_PAGES=1: the stand-in serves pages of the attach's size (160 records) whatever the pane asks, as the
/// bench did before it served the asked `limit` and `maxBytes`.
const ASKED_PAGE_SIZE = process.env.SMALL_PAGES !== "1";
/// SPLIT=1 (Chromium, implies PROFILE=1): a trace and CPU profile of the run, and each older page's ask to drawn cut
/// into the wait for its records, its fold, React's render and commit, and style and layout, plus the frames over
/// 16.7 ms and long tasks by what filled them (olderPageSplit.ts `OLDER-SPLIT` lines).
const SPLIT = process.env.SPLIT === "1";
/// RESTYLE=1 (Chromium): a timeline trace of the run, and the elements each frame restyled (UpdateLayoutTree's
/// elementCount, summed per painted frame). Its own runs: the trace slows the page, so read no frame times there.
const RESTYLE = process.env.RESTYLE === "1";
const PROFILE = process.env.PROFILE === "1" || SPLIT;

// The chat: the generated ordinary log at TURNS turns, its records as the stand-in daemon's lead steps; the
// papercut chat adds one finished turn after it ("Answer 1:"), which the page waits for. FIXTURE=flat: the
// papercut chat's own ROWS/2 turns.
const log = FLAT
  ? { events: [] as ReturnType<typeof godLog>["events"] }
  : godLog("small", { turns: TURNS, imageEvery: 25, chainEvery: 150 });
const lead: PapercutStep[] = log.events.map((event) => [
  event.dir,
  event.kind,
  event.msg as Record<string, unknown>,
  event.at,
]);
const chatTurns = FLAT ? Math.max(1, Math.floor(ROWS / 2)) : 1;
const prompts = FLAT ? chatTurns : log.events.filter((event) => event.kind === "user_message").length + 1;
/// The chat's first prompt's row (direct.ts names a prompt's row by its record's seq): the run is at the
/// top of the whole chat once that row is drawn at the view's top, not only at the loaded rows' top.
const FIRST_PROMPT = FLAT ? "user-1" : `user-${log.events.find((event) => event.kind === "user_message")!.seq}`;

/// `mounted`: rows (`.acpmux-row`) that came into the DOM since the frame before (a full mount each).
type Frame = {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
  paint: number;
  rows: string;
  mounted: number;
  writes?: string;
};

const percentile = (values: number[], p: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
};
const round2 = (value: number) => Math.round(value * 100) / 100;

async function run(name: string, engine: BrowserType) {
  let browser: Browser | undefined;
  browser = await engine.launch({ headless: true });
  const pane = await papercutPane(() => browser!, {
    turns: chatTurns,
    running: false,
    lead,
    attachPage: 160,
    session: { turnCount: prompts },
    eventsLatencyMs: LATENCY,
    daemonIndexes: true,
    askedPageSize: ASKED_PAGE_SIZE,
    // DEV=1 measures the dev server (React's development build); timing is of the production build.
    ...(process.env.DEV === "1" ? {} : { production: { minify: PROFILE ? false : undefined } }),
  });
  try {
    // Each older page on the wire (its `_acpmux/events` ask with `beforeSeq`, the reply's arrival and size)
    // and each ask the transcript makes and its settling (`__cmuxOlderTrace`), on the page's clock.
    // SPLIT=1: direct.ts's reply, fold and published phases kept by time, every phase stamped into the trace
    // (the page's clock there), and each React commit through the DevTools hook React calls in production too.
    // One init script, so the split's phases and the asks go through one `__cmuxOlderTrace` whatever order
    // init scripts run in.
    const page = await pane.open({ width: 1100, height: 800 }, async (page) => {
      await page.addInitScript((splitting: boolean) => {
        const wire = {
          sent: new Map<number, { before: number; limit: number; sentAt: number }>(),
          pages: [] as { before: number; limit: number; sentAt: number; recvAt: number; bytes: number }[],
          asks: new Map<number, { askAt: number; settledAt?: number }>(),
        };
        const split = splitting
          ? { reply: [] as number[], fold: [] as number[], published: [] as number[], commits: [] as number[] }
          : undefined;
        const holder = window as unknown as {
          __olderWire: typeof wire;
          __olderSplit?: NonNullable<typeof split>;
          __cmuxOlderTrace: (
            phase: "ask" | "settled" | "reply" | "fold" | "published",
            at: number,
            ask: number,
          ) => void;
          __REACT_DEVTOOLS_GLOBAL_HOOK__?: unknown;
        };
        holder.__olderWire = wire;
        holder.__cmuxOlderTrace = (phase, at, ask) => {
          if (split) {
            console.timeStamp(`cmux-older ${phase} ${ask} ${at}`);
            if (phase === "reply" || phase === "fold" || phase === "published") {
              split[phase].push(at);
              return;
            }
          }
          if (phase === "ask") wire.asks.set(ask, { askAt: at });
          else {
            const entry = wire.asks.get(ask);
            if (entry && entry.settledAt === undefined) entry.settledAt = at;
          }
        };
        const Native = window.WebSocket;
        window.WebSocket = class extends Native {
          constructor(...args: ConstructorParameters<typeof WebSocket>) {
            super(...args);
            this.addEventListener("message", (event: MessageEvent) => {
              if (wire.sent.size === 0 || typeof event.data !== "string") return;
              const id = /^\{"jsonrpc":"2\.0","id":(\d+)/.exec(event.data)?.[1];
              const asked = id === undefined ? undefined : wire.sent.get(Number(id));
              if (!asked) return;
              wire.sent.delete(Number(id));
              wire.pages.push({ ...asked, recvAt: performance.now(), bytes: event.data.length });
            });
          }
          override send(data: Parameters<WebSocket["send"]>[0]) {
            if (typeof data === "string" && data.includes('"_acpmux/events"') && data.includes('"beforeSeq"'))
              try {
                const sent = JSON.parse(data) as {
                  id: number;
                  params: { beforeSeq: number; limit: number; promptIndex?: boolean };
                };
                if (sent.params.promptIndex !== true)
                  wire.sent.set(sent.id, {
                    before: sent.params.beforeSeq,
                    limit: sent.params.limit,
                    sentAt: performance.now(),
                  });
              } catch {}
            super.send(data);
          }
        };
        if (!split) return;
        holder.__olderSplit = split;
        let renderers = 0;
        holder.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
          supportsFiber: true,
          renderers: new Map(),
          inject: () => ++renderers,
          checkDCE: () => {},
          onCommitFiberRoot: () => void split.commits.push(performance.now()),
          onCommitFiberUnmount: () => {},
          onPostCommitFiberRoot: () => {},
        };
      }, SPLIT);
    });
    await page.emulateMedia({ reducedMotion: "no-preference" });
    // PLAIN=1: no shadows, filters or blends, to tell an engine's raster cost from the page's work.
    if (process.env.PLAIN === "1")
      await page.addStyleTag({
        content:
          "*,*::before,*::after{box-shadow:none!important;filter:none!important;backdrop-filter:none!important;-webkit-backdrop-filter:none!important;mix-blend-mode:normal!important;text-shadow:none!important;mask:none!important;-webkit-mask:none!important}",
      });
    const view = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
    // The engine's own frame interval with nothing moving: headless engines on a CI host do not all
    // paint at 60 Hz, so the wheel's p95 reads against this floor.
    const idleP95 = await page.evaluate(
      () =>
        new Promise<number>((done) => {
          const at: number[] = [];
          const step = (now: number) => {
            at.push(now);
            if (at.length < 61) requestAnimationFrame(step);
            else {
              const gaps = at
                .slice(1)
                .map((each, index) => each - at[index]!)
                .sort((a, b) => a - b);
              done(gaps[Math.floor(gaps.length * 0.95)]!);
            }
          };
          requestAnimationFrame(step);
        }),
    );
    console.log(`transcript-scroll-up ${name} idleFrameP95: ${idleP95.toFixed(1)}`);
    // The thumb and long tasks, read after every painted frame for the whole run.
    await page.evaluate((logWrites) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const holder = window as unknown as {
        __upWatch: { frames: Frame[]; long: number[]; spans: [number, number][]; origin: number; stop(): void };
      };
      const frames: Frame[] = [];
      const long: number[] = [];
      const spans: [number, number][] = [];
      let observer: PerformanceObserver | undefined;
      try {
        observer = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            long.push(entry.duration);
            spans.push([entry.startTime, entry.startTime + entry.duration]);
          }
        });
        observer.observe({ type: "longtask", buffered: false });
      } catch {
        observer = undefined;
      }
      // Rows mounted since the last painted frame: each `.acpmux-row` added under the scroller.
      let mounted = 0;
      const rowsIn = new MutationObserver((records) => {
        for (const record of records)
          for (const node of record.addedNodes)
            if (node instanceof HTMLElement && node.classList.contains("acpmux-row")) mounted += 1;
      });
      rowsIn.observe(scroller, { childList: true, subtree: true });
      // LANDINGS=1: what each frame wrote under the transcript, by attribute and by nodes added or removed.
      let writes = new Map<string, number>();
      const count = (list: MutationRecord[]) => {
        for (const each of list) {
          const target = (each.target.nodeType === 1 ? each.target : each.target.parentElement) as Element | null;
          const where = target?.classList.contains("acpmux-row")
            ? "row"
            : target?.closest(".acpmux-row")
              ? "in-row"
              : (target?.className?.toString().split(" ")[0] ?? "?");
          const key =
            each.type === "attributes"
              ? `${where}@${each.attributeName}`
              : each.type === "childList"
                ? `${where}+${each.addedNodes.length}-${each.removedNodes.length}`
                : `${where}#text`;
          writes.set(key, (writes.get(key) ?? 0) + 1);
          // One sample of each style write a frame: what it was and what it became.
          if (each.type === "attributes" && each.attributeName === "style" && !samples.has(where))
            samples.set(where, `${each.oldValue ?? ""} => ${target?.getAttribute("style") ?? ""}`);
        }
      };
      let samples = new Map<string, string>();
      const mutations = logWrites ? new MutationObserver(count) : undefined;
      mutations?.observe(scroller, {
        subtree: true,
        attributes: true,
        attributeOldValue: true,
        childList: true,
        characterData: true,
      });
      const stopPaint = window.cmuxAfterPaint((paint) => {
        let written: string | undefined;
        if (mutations) {
          count(mutations.takeRecords());
          written =
            [...writes.entries()]
              .sort((a, b) => b[1] - a[1])
              .slice(0, 12)
              .map(([key, n]) => `${key}:${n}`)
              .join(" ") + ` | ${[...samples.entries()].map(([where, change]) => `${where}{${change}}`).join(" ")}`;
          writes = new Map();
          samples = new Map();
        }
        frames.push({
          ...(written !== undefined ? { writes: written } : {}),
          paint,
          scrollTop: scroller.scrollTop,
          scrollHeight: scroller.scrollHeight,
          clientHeight: scroller.clientHeight,
          // The mounted rows, first and last: a frame that mounts or unmounts rows changes them.
          rows: `${scroller.querySelector("[data-row-id]")?.getAttribute("data-row-id")}..${scroller.querySelectorAll("[data-row-id]").length}`,
          mounted,
        });
        mounted = 0;
      });
      const stop = () => {
        stopPaint();
        rowsIn.disconnect();
        mutations?.disconnect();
      };
      holder.__upWatch = {
        frames,
        long,
        spans,
        origin: performance.timeOrigin,
        stop: () => {
          stop();
          observer?.disconnect();
        },
      };
      (holder as unknown as { __longtasks: boolean }).__longtasks = observer !== undefined;
    }, process.env.LANDINGS === "1");
    // TRACE=1 (Chromium): the timeline of the wheel; each frame over 50 ms prints what took its time.
    const tracing =
      process.env.TRACE === "1" && name === "chromium" ? await page.context().newCDPSession(page) : undefined;
    const traceEvents: {
      name: string;
      ph: string;
      ts: number;
      dur?: number;
      tid: number;
      args?: Record<string, unknown>;
    }[] = [];
    if (tracing) {
      tracing.on(
        "Tracing.dataCollected",
        (event) => void traceEvents.push(...(event.value as unknown as typeof traceEvents)),
      );
      await tracing.send("Tracing.start", {
        categories: `toplevel,devtools.timeline,disabled-by-default-devtools.timeline,blink.user_timing${process.env.TRACE_WHY === "1" ? ",disabled-by-default-devtools.timeline.invalidationTracking" : ""}`,
        transferMode: "ReportEvents",
      });
    }
    // PROFILE=1 (Chromium): a CPU profile of the wheel, its busiest functions by self time printed at the end.
    let profiledAt = 0;
    const cdp = PROFILE && name === "chromium" ? await page.context().newCDPSession(page) : undefined;
    const splitting = SPLIT && name === "chromium";
    // The trace through CDP, as much as the browser keeps: Playwright's `startTracing` records until its buffer is
    // full, which a fling at 100k rows filled within its first two pages.
    const tracer = splitting ? await page.context().newCDPSession(page) : undefined;
    const restyler = RESTYLE && !tracer && name === "chromium" ? await page.context().newCDPSession(page) : undefined;
    if (restyler)
      await restyler.send("Tracing.start", {
        transferMode: "ReturnAsStream",
        traceConfig: { recordMode: "recordAsMuchAsPossible", includedCategories: ["devtools.timeline"] },
      });
    if (tracer)
      await tracer.send("Tracing.start", {
        transferMode: "ReturnAsStream",
        traceConfig: {
          recordMode: "recordAsMuchAsPossible",
          includedCategories: ["devtools.timeline", "disabled-by-default-devtools.timeline.stack"],
        },
      });
    if (cdp) {
      await cdp.send("Profiler.enable");
      // SPLIT=1 samples each 1 ms: at 250 us the profiler's own cost slowed every frame of a 100k-row fling.
      await cdp.send("Profiler.setSamplingInterval", { interval: SPLIT ? 1000 : 250 });
      await cdp.send("Profiler.start");
      profiledAt = (await page.evaluate(() => performance.now())) as number;
    }
    const traces: Awaited<ReturnType<typeof traceUpwardAnchors>>[] = [];
    const driftLog: string[] = [];
    const blankLog: string[] = [];
    const roundLog: string[] = [];
    const started = performance.now();
    let rounds = 0;
    for (; rounds < MAX_ROUNDS; rounds++) {
      const trace = await page.evaluate(traceUpwardAnchors, {
        steps: Array.from(
          { length: FRAMES_PER_ROUND },
          (_, frame) =>
            -STEP *
            (DRAG
              ? [2400, 4800, 3600, 3000][frame % 4]!
              : FLING
                ? [1500, 2400, 1900, 3000, 2100][frame % 5]!
                : [40.25, 95.5, 61.75, 128.125, 72.5, 101.25][frame % 6]!),
        ),
        restFrames: 0,
        drag: DRAG,
      });
      // Only what each frame showed is kept, not the row ids: a long run's samples are large.
      for (const sample of trace.samples) {
        if (sample.drift !== null && Math.abs(sample.drift) > 1 && driftLog.length < 10)
          driftLog.push(
            `round ${rounds} frame ${sample.frame}: ${sample.anchorId} moved ${sample.drift.toFixed(1)} px (wheel ${sample.wheelPixels.toFixed(1)}, top ${Math.round(sample.scrollTop)})`,
          );
        const blank =
          sample.topRowId === null ||
          sample.missingRow ||
          sample.unexpectedRowBoxGap > 1 / 64 ||
          Math.max(sample.topEdgeGap, sample.bottomEdgeGap) > 8;
        if (blank && blankLog.length < 10)
          blankLog.push(
            `round ${rounds} frame ${sample.frame}: top ${Math.round(sample.scrollTop)} row ${sample.topRowId} edge ${Math.round(sample.topEdgeGap)}/${Math.round(sample.bottomEdgeGap)} gap ${round2(sample.unexpectedRowBoxGap)} missing ${sample.missingRow} pair ${sample.unexpectedPair}`,
          );
      }
      traces.push({ ...trace, samples: trace.samples.map((sample) => ({ ...sample, rowBoxIds: [] })) });
      // Where each round left the view: the room held above the loaded rows, the offset and the height.
      if (roundLog.length < 40)
        roundLog.push(
          await page.evaluate(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const room = document.querySelector("[data-older-room]")?.getAttribute("data-older-room") ?? "0";
            return `room ${room} top ${Math.round(scroller.scrollTop)} height ${scroller.scrollHeight}`;
          }),
        );
      const atTop = await page.evaluate((first) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return !!document.querySelector(`[data-row-id="${first}"]`) && scroller.scrollTop <= 1;
      }, FIRST_PROMPT);
      if (atTop) break;
      if (PAGES > 0) {
        const drawn = await page.evaluate(
          () =>
            (window as unknown as { __olderWire: { asks: Map<number, { settledAt?: number }> } }).__olderWire.asks.size,
        );
        if (drawn >= PAGES) break;
      }
    }
    const watched = await page.evaluate(() => {
      const holder = window as unknown as {
        __upWatch: { frames: Frame[]; long: number[]; spans: [number, number][]; origin: number; stop(): void };
        __longtasks: boolean;
      };
      holder.__upWatch.stop();
      return {
        frames: holder.__upWatch.frames,
        long: holder.__upWatch.long,
        spans: holder.__upWatch.spans,
        longtasks: holder.__longtasks,
      };
    });
    if (tracing) {
      const done = new Promise<void>((resolve) => tracing.once("Tracing.tracingComplete", () => resolve()));
      await tracing.send("Tracing.end");
      await done;
      // The renderer's main thread: the thread with the most layouts and script calls.
      const main = new Map<number, number>();
      for (const event of traceEvents)
        if (event.name === "Layout" || event.name === "FunctionCall")
          main.set(event.tid, (main.get(event.tid) ?? 0) + 1);
      const tid = [...main.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
      const kinds = new Set([
        "Layout",
        "UpdateLayoutTree",
        "Paint",
        "PrePaint",
        "Layerize",
        "FunctionCall",
        "EventDispatch",
        "TimerFire",
        "FireAnimationFrame",
        "ParseHTML",
        "HitTest",
        "ScrollLayer",
        "UpdateLayer",
        "IntersectionObserverController::computeIntersections",
        "ResizeObserverController::notify",
        "Commit",
        "v8.run",
        "RunMicrotasks",
        "ProfileCall",
      ]);
      console.log(
        `transcript-scroll-up trace events ${traceEvents.length} main ${tid} runTasks ${traceEvents.filter((event) => event.tid === tid && event.name === "RunTask").length}`,
      );
      const tasks = traceEvents.filter(
        (event) =>
          event.tid === tid &&
          event.ph === "X" &&
          (event.name === "RunTask" || event.name === "ThreadControllerImpl::RunTask") &&
          (event.dur ?? 0) > 40_000,
      );
      for (const task of tasks.slice(0, 12)) {
        const end = task.ts + task.dur!;
        const by = new Map<string, number>();
        for (const event of traceEvents)
          if (event.tid === tid && event.ph === "X" && event.ts >= task.ts && event.ts < end && kinds.has(event.name)) {
            const detail =
              event.name === "FunctionCall"
                ? `FunctionCall ${(event.args?.data as { functionName?: string })?.functionName ?? ""}`
                : event.name === "Layout"
                  ? `Layout ${(event.args?.beginData as { dirtyObjects?: number })?.dirtyObjects ?? "?"}/${(event.args?.beginData as { totalObjects?: number })?.totalObjects ?? "?"} objects`
                  : event.name === "UpdateLayoutTree"
                    ? `Style ${(event.args?.elementCount as number) ?? (event.args?.beginData as { elementCount?: number })?.elementCount ?? "?"} elements`
                    : event.name;
            by.set(detail, (by.get(detail) ?? 0) + (event.dur ?? 0));
          }
        // TRACE_WHY=1: what invalidated the style and layout this task redid, by reason and node.
        if (process.env.TRACE_WHY === "1") {
          const why = new Map<string, number>();
          for (const event of traceEvents)
            if (
              event.tid === tid &&
              event.ts >= task.ts - 20_000 &&
              event.ts < end &&
              /InvalidationTracking/.test(event.name)
            ) {
              const data = (event.args?.data ?? {}) as Record<string, unknown> & {
                selectors?: { selector?: string }[];
              };
              const what = `${event.name.replace("InvalidationTracking", "")} ${String(data.reason ?? "")} ${String(data.changedAttribute ?? data.changedClass ?? data.changedPseudo ?? data.invalidatedSelectorId ?? "")} ${(
                data.selectors ?? []
              )
                .map((each) => each.selector)
                .join("|")
                .slice(0, 80)} ${String(data.nodeName ?? "")
                .replace(/ id='[^']*'/, "")
                .replace(/ class='([^' ]*)[^']*'/, " .$1")
                .slice(0, 60)}`;
              why.set(what, (why.get(what) ?? 0) + 1);
            }
          for (const [what, count] of [...why.entries()].sort((a, b) => b[1] - a[1]).slice(0, 14))
            console.log(`transcript-scroll-up trace why ${count}x ${what}`);
        }
        console.log(
          `transcript-scroll-up trace task ${Math.round(task.dur! / 1000)} ms: ${[...by.entries()]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 8)
            .map(([k, v]) => `${k} ${Math.round(v / 1000)}`)
            .join(", ")}`,
        );
      }
    }
    // Older pages: each ask the transcript made, to the first painted frame after it settled whose content
    // height changed (the page's rows drawn); and each page on the wire, ask to reply.
    const wire = await page.evaluate(() => {
      const held = (
        window as unknown as {
          __olderWire: {
            pages: { before: number; limit: number; sentAt: number; recvAt: number; bytes: number }[];
            asks: Map<number, { askAt: number; settledAt?: number }>;
          };
        }
      ).__olderWire;
      return { pages: held.pages, asks: [...held.asks.values()] };
    });
    const askToDrawn: number[] = [];
    const drawnAsks: { askAt: number; settledAt: number; drawnAt: number }[] = [];
    let cpuProfile: CpuProfile | undefined;
    let undrawnAsks = 0;
    for (const ask of wire.asks) {
      if (ask.settledAt === undefined) continue;
      const before = watched.frames.filter((frame) => frame.paint <= ask.settledAt!).at(-1);
      const drawn = watched.frames.find(
        (frame) => frame.paint > ask.settledAt! && (!before || frame.scrollHeight !== before.scrollHeight),
      );
      if (drawn && drawn.paint - ask.settledAt < 1000) {
        askToDrawn.push(drawn.paint - ask.askAt);
        // One line a page: bench/transcript-scroll-up-ab.sh pools them over repeats.
        console.log(
          `transcript-scroll-up ${name} page ${askToDrawn.length} askToDrawn ${round2(drawn.paint - ask.askAt)}`,
        );
        drawnAsks.push({ askAt: ask.askAt, settledAt: ask.settledAt, drawnAt: drawn.paint });
      } else undrawnAsks += 1;
    }
    const wireMs = wire.pages.map((each) => each.recvAt - each.sentAt);
    // A frame the reader asked to go up and the view moved less (held at the loaded rows' top, or a wheel
    // the pane cancelled there) while history was left above: the wait for a page, what a person sees as
    // loading.
    const loadingFrames = traces
      .flatMap((trace) => trace.samples)
      .filter(
        (sample) =>
          sample.requestedPixels < 0 && sample.wheelPixels > sample.requestedPixels + 1 && sample.scrollTop > 1,
      ).length;
    if (cdp) {
      type Node = {
        id: number;
        callFrame: { functionName: string; url: string; lineNumber: number };
        children?: number[];
      };
      const { profile } = (await cdp.send("Profiler.stop")) as unknown as {
        profile: { nodes: Node[]; samples: number[]; timeDeltas: number[]; startTime: number };
      };
      cpuProfile = profile;
      // Self time inside the long tasks only (each sample's page time: the profile's start, read on
      // the page, plus the deltas so far), by function.
      const inLong = new Map<string, number>();
      /// Inclusive time inside the long tasks: which of the page's functions a long task was spent under.
      const longTotal = new Map<string, number>();
      let clock = 0;
      const byId = new Map(profile.nodes.map((node) => [node.id, node]));
      const parents = new Map<number, Node>();
      for (const node of profile.nodes) for (const child of node.children ?? []) parents.set(child, node);
      const self = new Map<string, number>();
      const total = new Map<string, number>();
      const callers = new Map<string, number>();
      profile.samples.forEach((id, index) => {
        const ms = (profile.timeDeltas[index] ?? 0) / 1000;
        clock += ms;
        const node = byId.get(id)!;
        if (node.callFrame.functionName === "(idle)") return;
        const label = (each: Node) =>
          `${each.callFrame.functionName || "(anon)"} ${each.callFrame.url.split("/").pop()?.split("?")[0] ?? ""}:${each.callFrame.lineNumber + 1}`;
        self.set(label(node), (self.get(label(node)) ?? 0) + ms);
        const at = profiledAt + clock;
        if (watched.spans.some(([from, to]) => at >= from && at <= to)) {
          // Charged to the nearest frame of the page's own code, so a forced layout names its caller.
          let owner: Node | undefined = node;
          while (owner && !owner.callFrame.url) owner = parents.get(owner.id);
          const key = owner ? label(owner) : label(node);
          inLong.set(key, (inLong.get(key) ?? 0) + ms);
          const under = new Set<string>();
          for (let at: Node | undefined = node; at; at = parents.get(at.id)) {
            const each = label(at);
            if (under.has(each) || !at.callFrame.url) continue;
            under.add(each);
            longTotal.set(each, (longTotal.get(each) ?? 0) + ms);
          }
        }
        // A native frame (a forced layout in getBoundingClientRect, scrollTop) is charged to the
        // script that called it, so the page's own reads and the harness's read apart.
        if (!node.callFrame.url) {
          const caller = parents.get(node.id);
          if (caller) {
            const key = `${node.callFrame.functionName} <- ${label(caller)}`;
            callers.set(key, (callers.get(key) ?? 0) + ms);
          }
        }
        // Inclusive time per function, once per sample however deep it recurses.
        const seen = new Set<string>();
        for (let at: Node | undefined = node; at; at = parents.get(at.id)) {
          const key = label(at);
          if (seen.has(key) || !at.callFrame.url) continue;
          seen.add(key);
          total.set(key, (total.get(key) ?? 0) + ms);
        }
      });
      const top = (map: Map<string, number>, count: number) => [...map].sort((a, b) => b[1] - a[1]).slice(0, count);
      for (const [key, ms] of top(self, 30))
        console.log(`transcript-scroll-up profile self ${Math.round(ms)} ms ${key}`);
      for (const [key, ms] of top(inLong, 20))
        console.log(`transcript-scroll-up profile long ${Math.round(ms)} ms ${key}`);
      for (const [key, ms] of top(longTotal, 120))
        if (
          !/^(perform|flush|commit|recursively|render|update|begin|work|batched|dispatch|process|exports|reconcile|complete|mount|create|run|safely|bubble|SyntheticBaseEvent)/.test(
            key,
          )
        )
          console.log(`transcript-scroll-up profile longTotal ${Math.round(ms)} ms ${key}`);
      for (const [key, ms] of top(callers, 15))
        console.log(`transcript-scroll-up profile native ${Math.round(ms)} ms ${key}`);
      // The source at each of the busiest anonymous or bundled frames, since a bundle's line says little.
      const where = new Map<string, { url: string; line: number; column: number }>();
      for (const node of profile.nodes)
        if (node.callFrame.url)
          where.set(
            `${node.callFrame.functionName || "(anon)"} ${node.callFrame.url.split("/").pop()?.split("?")[0] ?? ""}:${node.callFrame.lineNumber + 1}`,
            {
              url: node.callFrame.url,
              line: node.callFrame.lineNumber,
              column: (node.callFrame as { columnNumber?: number }).columnNumber ?? 0,
            },
          );
      const sources = new Map<string, string[]>();
      const callerKeys = top(callers, 8).map(([key]) => key.split(" <- ")[1]!);
      for (const key of new Set([
        ...top(self, 20).map(([each]) => each),
        ...callerKeys,
        ...top(longTotal, 40)
          .map(([each]) => each)
          .filter(
            (each) =>
              /main-|subagentFold|perf-/.test(each) &&
              !/^(perform|flush|commit|recursively|render|update|begin|work|batched|dispatch|process|exports)/.test(
                each,
              ),
          ),
      ])) {
        const at = where.get(key);
        if (!at) continue;
        if (!sources.has(at.url))
          sources.set(
            at.url,
            ((await page.evaluate((url) => fetch(url).then((r) => r.text()), at.url)) as string).split("\n"),
          );
        const lines = sources.get(at.url)!;
        const line = lines[at.line] ?? "";
        const after = lines
          .slice(at.line + 1, at.line + 7)
          .map((each) => each.trim())
          .join(" | ");
        console.log(
          `transcript-scroll-up profile at ${key}: ${line.slice(Math.max(0, at.column - 40), at.column + 160).trim()} | ${after.slice(0, 400)}`,
        );
      }
      for (const [key, ms] of top(total, 40))
        console.log(`transcript-scroll-up profile total ${Math.round(ms)} ms ${key}`);
    }
    if (tracer) {
      const complete = new Promise<{ stream?: string; dataLossOccurred?: boolean }>((done) =>
        tracer.once("Tracing.tracingComplete", done),
      );
      await tracer.send("Tracing.end");
      const { stream, dataLossOccurred } = await complete;
      const chunks: string[] = [];
      for (;;) {
        const read = await tracer.send("IO.read", { handle: stream! });
        chunks.push(read.base64Encoded ? Buffer.from(read.data, "base64").toString() : read.data);
        if (read.eof) break;
      }
      await tracer.send("IO.close", { handle: stream! });
      const text = chunks.join("");
      const parsed = JSON.parse(text) as { traceEvents?: unknown[] } | unknown[];
      const events = (Array.isArray(parsed) ? parsed : (parsed.traceEvents ?? [])) as Parameters<
        typeof reportOlderSplit
      >[0];
      console.log(
        `OLDER-SPLIT trace ${events.length} events, ${Math.round(text.length / 1048576)} MiB, data lost: ${dataLossOccurred === true}`,
      );
      const split = (await page.evaluate(
        () => (window as unknown as { __olderSplit: Record<string, number[]> }).__olderSplit,
      )) as Record<"reply" | "fold" | "published" | "commits", number[]>;
      reportOlderSplit(events, cpuProfile, {
        asks: drawnAsks,
        ...split,
        frames: traces.map((trace) => trace.samples.map((sample) => sample.paint)),
        longSpans: watched.spans,
      });
    }
    // RESTYLE=1: the elements restyled over the run, per painted frame and per style pass.
    let restyled: { perFrame: number; passP95: number; passMax: number; lost: boolean } | undefined;
    if (restyler) {
      const complete = new Promise<{ stream?: string; dataLossOccurred?: boolean }>((done) =>
        restyler.once("Tracing.tracingComplete", done),
      );
      await restyler.send("Tracing.end");
      const { stream, dataLossOccurred } = await complete;
      const chunks: string[] = [];
      for (;;) {
        const read = await restyler.send("IO.read", { handle: stream! });
        chunks.push(read.base64Encoded ? Buffer.from(read.data, "base64").toString() : read.data);
        if (read.eof) break;
      }
      await restyler.send("IO.close", { handle: stream! });
      const parsed = JSON.parse(chunks.join("")) as { traceEvents?: unknown[] } | unknown[];
      const events = (Array.isArray(parsed) ? parsed : (parsed.traceEvents ?? [])) as {
        name?: string;
        ph?: string;
        args?: { elementCount?: number; data?: { elementCount?: number } };
      }[];
      const passes = events
        .filter((event) => event.name === "UpdateLayoutTree" && (event.ph === "X" || event.ph === "E"))
        .map((event) => event.args?.elementCount ?? event.args?.data?.elementCount ?? 0);
      const painted = Math.max(1, watched.frames.length);
      restyled = {
        perFrame: round2(passes.reduce((sum, count) => sum + count, 0) / painted),
        passP95: percentile(passes, 95),
        passMax: Math.max(0, ...passes),
        lost: dataLossOccurred === true,
      };
    }
    const reachedTop = rounds < MAX_ROUNDS;
    const pages = pane.methods.filter((method) => method === "_acpmux/events").length;
    const samples = traces.flatMap((trace) => trace.samples);
    const intervals: number[] = [];
    for (const trace of traces)
      for (let index = 1; index < trace.samples.length; index++)
        intervals.push(trace.samples[index]!.paint - trace.samples[index - 1]!.paint);
    const blankFrames = samples.filter(
      (sample) =>
        sample.topRowId === null ||
        sample.missingRow ||
        sample.unexpectedRowBoxGap > 1 / 64 ||
        Math.max(sample.topEdgeGap, sample.bottomEdgeGap) > 8,
    ).length;
    const emptyFrames = samples.filter((sample) => sample.topRowId === null).length;
    const drifts = samples.filter((sample) => sample.drift !== null).map((sample) => Math.abs(sample.drift!));
    const shifted = drifts.filter((drift) => drift > 1).length;
    // The thumb: its size is the viewport's share of the content; its top, that share of the offset.
    const frames = watched.frames.filter((frame) => frame.scrollHeight > frame.clientHeight);
    const size = (frame: Frame) => frame.clientHeight / frame.scrollHeight;
    const thumbTop = (frame: Frame) => (frame.scrollTop / frame.scrollHeight) * frame.clientHeight;
    const first = frames[0] ? size(frames[0]) : 0;
    let sizeChange = 0;
    let thumbDown = 0;
    let thumbDownMax = 0;
    for (let index = 0; index < frames.length; index++) {
      sizeChange = Math.max(sizeChange, Math.abs(size(frames[index]!) / first - 1));
      if (index === 0) continue;
      const moved = thumbTop(frames[index]!) - thumbTop(frames[index - 1]!);
      if (moved > 1) {
        thumbDown += 1;
        thumbDownMax = Math.max(thumbDownMax, moved);
      }
    }
    const summary = {
      engine: name,
      turns: TURNS,
      step: STEP,
      fling: FLING,
      latencyMs: LATENCY,
      reachedTop,
      rounds: rounds + 1,
      pages,
      seconds: round2((performance.now() - started) / 1000),
      frames: samples.length,
      wheelPx: Math.round(samples.reduce((sum, sample) => sum + sample.wheelPixels, 0)),
      cancelledWheels: traces.reduce((sum, trace) => sum + trace.cancelledWheels, 0),
      blankFrames,
      emptyFrames,
      maxEdgeGap: Math.round(
        Math.max(0, ...samples.map((sample) => Math.max(sample.topEdgeGap, sample.bottomEdgeGap))),
      ),
      driftMax: round2(Math.max(0, ...drifts)),
      driftFrames: shifted,
      driftSum: Math.round(drifts.reduce((sum, drift) => sum + drift, 0)),
      frameP50: round2(percentile(intervals, 50)),
      frameP95: round2(percentile(intervals, 95)),
      // Frames split by what they did: a page landing (the content's height changed), a frame that
      // mounted or unmounted rows with no landing, and a frame that only scrolled.
      ...(() => {
        const kinds = { landing: [] as number[], mount: [] as number[], scroll: [] as number[] };
        for (let index = 1; index < watched.frames.length; index++) {
          const [was, now] = [watched.frames[index - 1]!, watched.frames[index]!];
          const kind = now.scrollHeight !== was.scrollHeight ? "landing" : now.rows !== was.rows ? "mount" : "scroll";
          if (process.env.LANDINGS === "1" && kind === "landing")
            console.log(
              `transcript-scroll-up ${name} landing gap ${round2(now.paint - was.paint)} rows ${was.rows} -> ${now.rows} height ${was.scrollHeight} -> ${now.scrollHeight} next ${round2((watched.frames[index + 1]?.paint ?? now.paint) - now.paint)} writes ${now.writes ?? ""}`,
            );
          kinds[kind].push(now.paint - was.paint);
        }
        return Object.fromEntries(
          Object.entries(kinds).flatMap(([kind, gaps]) => [
            [`${kind}Frames`, gaps.length],
            [`${kind}P95`, round2(percentile(gaps, 95))],
            [`${kind}Max`, round2(Math.max(0, ...gaps))],
          ]),
        );
      })(),
      frameMax: round2(Math.max(0, ...intervals)),
      longTasks: watched.longtasks ? watched.long.length : null,
      longTaskMs: watched.longtasks ? Math.round(watched.long.reduce((sum, ms) => sum + ms, 0)) : null,
      thumbSizeStartPct: round2(first * 100),
      thumbSizeEndPct: round2(frames.length ? size(frames.at(-1)!) * 100 : 0),
      thumbSizeChangePct: round2(sizeChange * 100),
      thumbDown,
      thumbDownMax: round2(thumbDownMax),
      mode: MODE,
      fixture: FLAT ? `flat ${ROWS} rows` : `ordinary ${TURNS} turns`,
      asks: wire.asks.length,
      askToDrawnP50: round2(percentile(askToDrawn, 50)),
      askToDrawnP95: round2(percentile(askToDrawn, 95)),
      askToDrawnMax: round2(Math.max(0, ...askToDrawn)),
      undrawnAsks,
      loadingFrames,
      wirePages: wire.pages.length,
      wireMsP50: round2(percentile(wireMs, 50)),
      wireMsP95: round2(percentile(wireMs, 95)),
      wireKiBP50: round2(
        percentile(
          wire.pages.map((each) => each.bytes / 1024),
          50,
        ),
      ),
      wireKiBMax: round2(Math.max(0, ...wire.pages.map((each) => each.bytes / 1024))),
      // Rows mounted per painted frame while the run scrolled (`Frame.mounted`).
      mountedRowsP95: percentile(
        watched.frames.map((frame) => frame.mounted),
        95,
      ),
      mountedRowsMax: Math.max(0, ...watched.frames.map((frame) => frame.mounted)),
      mountedRowsPerFrame: round2(
        watched.frames.reduce((sum, frame) => sum + frame.mounted, 0) / Math.max(1, watched.frames.length),
      ),
      ...(restyled
        ? {
            restyledPerFrame: restyled.perFrame,
            restyledPassP95: restyled.passP95,
            restyledPassMax: restyled.passMax,
            restyleTraceLost: restyled.lost,
          }
        : {}),
    };
    for (const [key, value] of Object.entries(summary))
      if (key !== "engine") console.log(`transcript-scroll-up ${name} ${key}: ${JSON.stringify(value)}`);
    for (const line of blankLog) console.log(`transcript-scroll-up ${name} blank ${line}`);
    for (const line of driftLog) console.log(`transcript-scroll-up ${name} drift ${line}`);
    for (const [at, line] of roundLog.entries()) console.log(`transcript-scroll-up ${name} round ${at} ${line}`);
    // The first painted frames' heights: whether the room was there when the reader began.
    console.log(
      `transcript-scroll-up ${name} first heights: ${watched.frames
        .slice(0, 6)
        .map((frame) => frame.scrollHeight)
        .join(" ")}`,
    );
    perfRow({ name: `transcript_scroll_up.${name}.interval`, p50: summary.frameP50, p95: summary.frameP95 });
    perfRow({
      name: `transcript_scroll_up.${name}.${MODE}.older_page_drawn`,
      p50: summary.askToDrawnP50,
      p95: summary.askToDrawnP95,
    });
    await page.close();
    return summary;
  } finally {
    await pane.close();
    await browser.close();
  }
}

/// The engine's own cost of the same wheel on a static page as tall as the chat (paragraphs, no
/// script): the frame p95 a headless engine on this host reaches with no app work at all. WebKit
/// on a Linux CI host paints in software and does not reach 60 Hz here even so; the app's frames
/// are held to the budget or to this floor, whichever is higher.
async function scrollFloor(engine: BrowserType): Promise<number> {
  const browser = await engine.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.setContent(
      `<div id="s" style="height:800px;overflow:auto;font:14px/20px sans-serif">${Array.from(
        { length: 2400 },
        (_, index) =>
          `<p style="margin:0 0 24px;padding:8px 12px;border-radius:8px;background:#f4f4f4">Turn ${index}: ${"some reply text that wraps across the line ".repeat(4)}</p>`,
      ).join("")}</div>`,
    );
    return await page.evaluate(
      ({ steps }) =>
        new Promise<number>((done) => {
          const scroller = document.getElementById("s")!;
          scroller.scrollTop = scroller.scrollHeight;
          const at: number[] = [];
          let frame = 0;
          const tick = (now: number) => {
            at.push(now);
            scroller.scrollTop -= steps[frame % steps.length]!;
            frame += 1;
            if (frame < 600) requestAnimationFrame(tick);
            else {
              const gaps = at
                .slice(1)
                .map((each, index) => each - at[index]!)
                .sort((a, b) => a - b);
              done(gaps[Math.floor(gaps.length * 0.95)]!);
            }
          };
          requestAnimationFrame(tick);
        }),
      { steps: [40.25, 95.5, 61.75, 128.125, 72.5, 101.25].map((step) => step * STEP) },
    );
  } finally {
    await browser.close();
  }
}

/// A vsync interval's jitter: a 60 Hz rAF interval reads 16.6 to 16.8 ms.
const FRAME_JITTER_MS = 0.5;

let failed = false;
for (const name of ENGINES) {
  const engine = name === "webkit" ? webkit : name === "chromium" ? chromium : undefined;
  if (!engine) throw new Error(`unknown engine ${name}`);
  const floor = await scrollFloor(engine);
  console.log(`transcript-scroll-up ${name} staticScrollP95: ${round2(floor)}`);
  const budget = Math.max(FRAME_BUDGET_MS, floor) + FRAME_JITTER_MS;
  const result = await run(name, engine);
  const misses = [
    !result.reachedTop && "did not reach the first prompt",
    result.blankFrames > 0 && `${result.blankFrames} blank frames`,
    result.driftMax >= 1 && `drift ${result.driftMax} px`,
    result.frameP95 > budget && `p95 frame ${result.frameP95} ms over ${round2(budget)}`,
    (result.longTasks ?? 0) > 0 && `${result.longTasks} long tasks (${result.longTaskMs} ms)`,
    result.thumbSizeChangePct > 5 && `thumb size changed ${result.thumbSizeChangePct} %`,
    result.thumbDown > 0 && `thumb moved down on ${result.thumbDown} frames`,
  ].filter(Boolean);
  console.log(`transcript-scroll-up ${name} verdict: ${misses.length ? `MISS (${misses.join(", ")})` : "PASS"}`);
  if (misses.length) failed = true;
}
process.exit(failed ? 1 : 0);
