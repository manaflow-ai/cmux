// The trace reading behind chat-render-pipeline-budgets.test.ts: its budgets, and the style/layout passes and key tasks
// it reads from a Chromium trace. A support module so the test file holds only its browser lane.
import type { Browser, Page } from "playwright";

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
/** Forced passes from transcript code per typed key, in the key's own tasks. The doc's stage 7 wants none; today a key's
 * discrete React commit runs the transcript's layout effects (`pinLiveLine`, `giveRoomNearTop`, the pinned live line's
 * `getAnimations`) in the key's task, so this holds them at the measured level until that moves out. */
export const TRANSCRIPT_FORCED_PER_KEY = 1;
/** Transcript code, for TRANSCRIPT_FORCED_PER_KEY. */
export const TRANSCRIPT =
  /VirtualTranscript|turnEndFold|Thinking\.tsx|scrollCoordinates|RevealedMarkdown|revealedMarkdownModel|tailGlide|pinnedLiveLine/;

export const MEASURE = process.env.CHAT_RENDER_MEASURE === "1";
export const PROMPT =
  ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const CATEGORIES = [
  "toplevel",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-devtools.timeline.stack",
  "blink.user_timing",
];
/** The test's own driver: its per-frame reads of the scroller are the harness's, not the pane's. */
export const HARNESS = /loadDebug|debug\.ts|playwright|__puppeteer|pptr:/;

export type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  pid: number;
  tid: number;
  args?: Record<string, any>;
};
export type Pass = { kind: "style" | "layout"; ts: number; elements: number; stack: string | undefined };

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

export function markAt(events: TraceEvent[], name: string): number | undefined {
  return events.find((e) => e.name === name)?.ts;
}

const percentile = (values: number[], q: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};

export function summary(list: Pass[], scrollElements: number) {
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

export async function trace(browser: Browser, page: Page, run: () => Promise<unknown>): Promise<TraceEvent[]> {
  await browser.startTracing(page, { categories: CATEGORIES });
  await run();
  return (JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: TraceEvent[] }).traceEvents;
}
