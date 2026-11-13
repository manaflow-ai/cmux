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
//   TURNS=600 ENGINES=webkit,chromium STEP=1 bun bench/transcript-scroll-up.bench.ts
// STEP scales the wheel's steps (1: about 80 px a frame, a trackpad flick; 0.4 a reading scroll). Prints one
// summary line per engine and PERF_ROW lines; exits 1 when a goal is missed (0 blank frames, drift under 1 px,
// p95 frame under 16.7 ms, thumb size change under 5 %, thumb never moving down). Run it yourself, never as a CI
// gate (`cmux-ci test -- 'cd webviews && bun bench/transcript-scroll-up.bench.ts'`).
/// <reference types="bun" />
import { chromium, webkit } from "./browsers";
import type { Browser, BrowserType } from "playwright";
import { godLog } from "./godFixture";
import { papercutPane, type PapercutStep } from "../test/support/papercutChat";
import { traceUpwardAnchors } from "../test/support/upwardAnchorTrace";
import { perfRow } from "./perfRow";

const TURNS = Number(process.env.TURNS ?? 600);
const STEP = Number(process.env.STEP ?? 1);
const ENGINES = (process.env.ENGINES ?? "webkit,chromium").split(",").filter(Boolean);
const MAX_ROUNDS = Number(process.env.ROUNDS ?? 400);
const FRAMES_PER_ROUND = 120;
const FRAME_BUDGET_MS = 1000 / 60;
/// FLING=1: a fast fling instead of a trackpad scroll, each frame's wheel 1,500 to 3,000 px.
const FLING = process.env.FLING === "1";
/// LATENCY=ms: each older page lands that late, as from a remote or busy acpmux.
const LATENCY = Number(process.env.LATENCY ?? 0);

// The chat: the generated ordinary log at TURNS turns, its records as the stand-in daemon's lead steps; the
// papercut chat adds one finished turn after it ("Answer 1:"), which the page waits for.
const log = godLog("small", { turns: TURNS, imageEvery: 25, chainEvery: 150 });
const lead: PapercutStep[] = log.events.map((event) => [
  event.dir,
  event.kind,
  event.msg as Record<string, unknown>,
  event.at,
]);
const prompts = log.events.filter((event) => event.kind === "user_message").length + 1;
/// The chat's first prompt's row (direct.ts names a prompt's row by its record's seq): the run is at the
/// top of the whole chat once that row is drawn at the view's top, not only at the loaded rows' top.
const FIRST_PROMPT = `user-${log.events.find((event) => event.kind === "user_message")!.seq}`;

type Frame = {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
  paint: number;
  rows: string;
  writes?: string;
  /// WHY=1: where the frame's main-thread time went (ms): scroll handlers, frame callbacks (the
  /// drive's wheel and offset write, the app's pacer), and the rest of the rendering update (style,
  /// layout, observers, paint), from its first scroll event or frame callback to the task after it.
  why?: { scroll: number; raf: number; render: number; busy: number; between: number; layout: number };
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
    turns: 1,
    running: false,
    lead,
    attachPage: 160,
    session: { turnCount: prompts },
    eventsLatencyMs: LATENCY,
    daemonIndexes: true,
    // DEV=1 measures the dev server (React's development build); timing is of the production build.
    ...(process.env.DEV === "1" ? {} : { production: { minify: process.env.PROFILE === "1" ? false : undefined } }),
  });
  try {
    const page = await pane.open({ width: 1100, height: 800 });
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
    // ABLATE=a,b: switch a suspected per-frame cost off, to weigh it (bench-only CSS).
    const ablations: Record<string, string> = {
      // The soft edges: a mask on the scroller, its reach moved by every scroll.
      mask: ".acpmux-scroll{-webkit-mask-image:none!important;mask-image:none!important}",
      // The thread as its own layer under the scroller's mask.
      threadlayer: ".acpmux-thread{will-change:transform}",
      // The soft edges as a mask on a non-scrolling ancestor, not on the scroller (cost only: this
      // also masks the stage's other children).
      stagemask:
        ".acpmux-scroll{-webkit-mask-image:none!important;mask-image:none!important}.acpmux-stage{-webkit-mask-image:linear-gradient(to bottom,transparent 0,#000 18px,#000 calc(100% - 140px),transparent calc(100% - 122px));mask-image:linear-gradient(to bottom,transparent 0,#000 18px,#000 calc(100% - 140px),transparent calc(100% - 122px))}",
      // The scroller's content as one composited scrolling layer.
      scrolllayer: ".acpmux-spacer{will-change:transform}",
      // The thread paints only inside its own box.
      threadpaint: ".acpmux-thread{contain:layout style}",
      // The soft edges drawn as overlays in the page color instead of a mask (cost only).
      overlay:
        ".acpmux-scroll{-webkit-mask-image:none!important;mask-image:none!important}.acpmux-stage::before,.acpmux-stage::after{content:'';position:absolute;left:0;right:0;height:18px;z-index:5;pointer-events:none}.acpmux-stage::before{top:0;background:linear-gradient(var(--agent-page-bg),transparent)}.acpmux-stage::after{bottom:120px;background:linear-gradient(transparent,var(--agent-page-bg))}",
      // The soft edges as one still layer cut by a mask, instead of the two gradient bands
      // (softEdges.gallery.ts `static-mask`).
      staticmask:
        ":root .acpmux-edges__veil::before,:root .acpmux-edges__veil::after{content:none!important}:root .acpmux-edges__veil{bottom:auto;background:linear-gradient(var(--acpmux-veil-ink),var(--acpmux-veil-ink)),var(--acpmux-veil-ground);-webkit-mask-image:linear-gradient(to bottom,#000 var(--acpmux-veil-top),transparent calc(var(--acpmux-veil-top) + var(--acpmux-veil-top-fade)),transparent calc(100% - var(--acpmux-veil-dock) - var(--acpmux-veil-bottom-fade)),#000 calc(100% - var(--acpmux-veil-dock)));mask-image:linear-gradient(to bottom,#000 var(--acpmux-veil-top),transparent calc(var(--acpmux-veil-top) + var(--acpmux-veil-top-fade)),transparent calc(100% - var(--acpmux-veil-dock) - var(--acpmux-veil-bottom-fade)),#000 calc(100% - var(--acpmux-veil-dock)))}",
      // Rows away from the view skip their rendering.
      cv: ".acpmux-row{content-visibility:auto;contain-intrinsic-size:auto 200px}",
      // Rows as their own paint layers.
      layer: ".acpmux-row{will-change:transform}",
      // The minimap rail and scroll map.
      minimap: ".acpmux-minimap,.acpmux-chat-minimap{display:none!important}",
    };
    // DROP=has,sib,nth,attr: delete every rule whose selector uses that feature (cost only), to
    // find the selectors that make a row inserted or an attribute written restyle the whole thread.
    if (process.env.DROP) {
      const dropped = await page.evaluate((kinds) => {
        const tests: Record<string, RegExp> = {
          has: /:has\(/,
          sib: /[~+]|:(first|last|only|nth)-(child|of-type)|:(first|last|only)-child|:nth-/,
          not: /:not\(/,
          attr: /\[data-(older|loads|fade|docked|jump|cmux)/,
        };
        const kill = kinds.split(",").map((kind) => tests[kind]!);
        let count = 0;
        const walk = (rules: CSSRuleList, owner: CSSStyleSheet | CSSGroupingRule) => {
          for (let index = rules.length - 1; index >= 0; index -= 1) {
            const rule = rules[index]!;
            if (rule instanceof CSSStyleRule && kill.some((test) => test.test(rule.selectorText))) {
              owner.deleteRule(index);
              count += 1;
            } else if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules)
              walk((rule as CSSGroupingRule).cssRules, rule as CSSGroupingRule);
          }
        };
        for (const sheet of document.styleSheets) {
          try {
            walk(sheet.cssRules, sheet);
          } catch {}
        }
        return count;
      }, process.env.DROP);
      console.log(`transcript-scroll-up ${name} dropped ${dropped} rules (${process.env.DROP})`);
    }
    for (const key of (process.env.ABLATE ?? "").split(",").filter(Boolean)) {
      if (!ablations[key]) throw new Error(`unknown ABLATE ${key}`);
      await page.addStyleTag({ content: ablations[key]! });
    }
    // The thumb and long tasks, read after every painted frame for the whole run.
    await page.evaluate(
      ({ logWrites, why }) => {
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
        const mutations = logWrites || why ? new MutationObserver(count) : undefined;
        // WHY=1: per-frame timing. The window's capture sees a frame's first scroll event before any
        // handler; a listener added now on the scroller runs after the app's own. Frame callbacks
        // registered from now on (the drive's, the pacer's) are timed by wrapping them.
        let frameStart: number | undefined;
        let scrollStart: number | undefined;
        let scrollMs = 0;
        let rafMs = 0;
        let rafEnd: number | undefined;
        let lastRead: number | undefined;
        // Style and layout: a probe resized in each frame's callbacks is reported by a ResizeObserver,
        // which runs once the frame's style and layout are done, before its paint.
        let layoutMs = 0;
        let probeOn = false;
        const probe = document.createElement("div");
        probe.style.cssText = "position:fixed;left:-10px;top:0;width:1px;height:1px;pointer-events:none";
        if (why) {
          document.body.append(probe);
          new ResizeObserver(() => {
            if (rafEnd !== undefined) layoutMs = performance.now() - rafEnd;
          }).observe(probe);
          addEventListener(
            "scroll",
            () => {
              const now = performance.now();
              scrollStart = now;
              frameStart ??= now;
            },
            { capture: true, passive: true },
          );
          scroller.addEventListener(
            "scroll",
            () => {
              if (scrollStart !== undefined) scrollMs += performance.now() - scrollStart;
              scrollStart = undefined;
            },
            { passive: true },
          );
          const raf = window.requestAnimationFrame.bind(window);
          window.requestAnimationFrame = (callback) =>
            raf((time) => {
              const start = performance.now();
              frameStart ??= start;
              try {
                callback(time);
              } finally {
                rafEnd = performance.now();
                rafMs += rafEnd - start;
                probeOn = !probeOn;
                probe.style.width = probeOn ? "2px" : "1px";
              }
            });
        }
        mutations?.observe(scroller, {
          subtree: true,
          attributes: true,
          attributeOldValue: true,
          childList: true,
          characterData: true,
        });
        const stop = window.cmuxAfterPaint((paint) => {
          const readAt = performance.now();
          const timing =
            why && frameStart !== undefined
              ? {
                  scroll: scrollMs,
                  raf: rafMs,
                  render: readAt - (rafEnd ?? frameStart),
                  busy: readAt - frameStart,
                  between: lastRead === undefined ? 0 : frameStart - lastRead,
                  layout: layoutMs,
                }
              : undefined;
          frameStart = undefined;
          layoutMs = 0;
          scrollMs = 0;
          rafMs = 0;
          rafEnd = undefined;
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
            ...(timing ? { why: timing } : {}),
            paint,
            scrollTop: scroller.scrollTop,
            scrollHeight: scroller.scrollHeight,
            clientHeight: scroller.clientHeight,
            // The mounted rows, first and last: a frame that mounts or unmounts rows changes them.
            rows: `${scroller.querySelector("[data-row-id]")?.getAttribute("data-row-id")}..${scroller.querySelectorAll("[data-row-id]").length}`,
          });
          lastRead = performance.now();
        });
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
      },
      { logWrites: process.env.LANDINGS === "1", why: process.env.WHY === "1" },
    );
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
    const cdp =
      process.env.PROFILE === "1" && name === "chromium" ? await page.context().newCDPSession(page) : undefined;
    if (cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 250 });
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
            (FLING
              ? [1500, 2400, 1900, 3000, 2100][frame % 5]!
              : [40.25, 95.5, 61.75, 128.125, 72.5, 101.25][frame % 6]!),
        ),
        restFrames: 0,
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
    if (cdp) {
      type Node = {
        id: number;
        callFrame: { functionName: string; url: string; lineNumber: number };
        children?: number[];
      };
      const { profile } = (await cdp.send("Profiler.stop")) as unknown as {
        profile: { nodes: Node[]; samples: number[]; timeDeltas: number[] };
      };
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
        const whyBy: Record<string, NonNullable<Frame["why"]>[]> = {};
        const scrollWrites: string[] = [];
        for (let index = 1; index < watched.frames.length; index++) {
          const [was, now] = [watched.frames[index - 1]!, watched.frames[index]!];
          const kind = now.scrollHeight !== was.scrollHeight ? "landing" : now.rows !== was.rows ? "mount" : "scroll";
          if (process.env.LANDINGS === "1" && kind === "landing")
            console.log(
              `transcript-scroll-up ${name} landing gap ${round2(now.paint - was.paint)} rows ${was.rows} -> ${now.rows} height ${was.scrollHeight} -> ${now.scrollHeight} next ${round2((watched.frames[index + 1]?.paint ?? now.paint) - now.paint)} writes ${now.writes ?? ""}`,
            );
          kinds[kind].push(now.paint - was.paint);
          if (now.why) (whyBy[kind] ??= []).push(now.why);
          if (process.env.WHY === "1" && kind === "scroll" && now.writes)
            scrollWrites.push(now.writes.split(" | ")[0]!);
        }
        // WHY=1: each kind's frames by where their time went, p50/p95 of each part.
        if (process.env.WHY === "1") {
          for (const [kind, list] of Object.entries(whyBy)) {
            const part = (key: keyof NonNullable<Frame["why"]>) =>
              `${key} ${round2(
                percentile(
                  list.map((each) => each[key]),
                  50,
                ),
              )}/${round2(
                percentile(
                  list.map((each) => each[key]),
                  95,
                ),
              )}`;
            console.log(
              `transcript-scroll-up ${name} why ${kind} (${list.length} frames, p50/p95 ms): ${part("busy")} ${part("scroll")} ${part("raf")} ${part("render")} ${part("between")} ${part("layout")}`,
            );
          }
          // What scroll-only frames wrote, summed over the run.
          const total = new Map<string, number>();
          for (const line of scrollWrites)
            for (const item of line.split(" ")) {
              const at = item.lastIndexOf(":");
              if (at > 0)
                total.set(item.slice(0, at), (total.get(item.slice(0, at)) ?? 0) + Number(item.slice(at + 1)));
            }
          console.log(
            `transcript-scroll-up ${name} why scroll writes over ${scrollWrites.length} frames: ${[...total.entries()]
              .sort((a, b) => b[1] - a[1])
              .slice(0, 16)
              .map(([key, n]) => `${key}:${n}`)
              .join(" ")}`,
          );
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
