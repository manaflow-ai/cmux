// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A streaming reply as the agent pane draws it (App.tsx): the real VirtualTranscript over a chat's
// history, with a stand-in for the bottom stack laid over its foot (bottomStack.css) as the docked
// composer is, after the first send (the strip's 46 px placeholder over a one-line card). A long
// Markdown reply arrives in deltas on timers, as a socket's do, at Claude's cadence (16 characters
// every 50 ms) or Codex's (runs of tokens a few ms apart, then 100-500 ms pauses, from a seeded
// PRNG). Each delta grows the row's text and bumps its version, and one snapshot draws per display
// frame however many deltas land in it (direct.ts `emitInFrame` with main.tsx's `nextFrame`); the
// app also keeps each snapshot for a reload (App.tsx `saveSnapshot`), which this does too. The stream
// ends as a turn does: the row stops streaming and the turn's summary row comes in. The highlighted
// code card's chunk loads before the reply starts, as the app loads it once its first frame paints.
//
// `window.__streamingText.run({ cadence })` streams the reply once and samples every display frame
// while it streams and for a second after: frame intervals, long tasks and each frame's main-thread
// work (streaming-text.clock.ts), how
// much of the reply shows on each frame, where each drawn block of the reply sits, how far the view
// rests from its end, and the room between the reply's last line and the bottom stack. It resolves
// with a report (streaming-text-frames.test.ts reads it).
import { spans, untimedFrame } from "./streaming-text.clock";
import { useState } from "react";
import { FileRenderer, File as PierreFile } from "@pierre/diffs";
import { createRoot } from "react-dom/client";
import { saveSnapshot, VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { loadHighlightedCode } from "../../src/agent-session/acpmux/conversation/CodeBlock";
import { nextFrame } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "../../src/agent-session/acpmux/model";
import { percentile, round2 } from "../../src/agent-session/acpmux/perf";
import { StreamReveal } from "../../src/agent-session/acpmux/streamReveal";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import {
  history,
  REPLY,
  schedule,
  type Cadence,
  type Delta,
} from "../../src/agent-session/acpmux/conversation/streamingTextFixture";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/previewCard/previewCard.css";
import "../../src/agent-session/acpmux/changes/changes.css";
import "../../src/agent-session/acpmux/turnChanges/turnChanges.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/keys.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

type Stats = { p50: number; p95: number; max: number };
const stats = (values: number[]): Stats => {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    p50: round2(percentile(sorted, 0.5)),
    p95: round2(percentile(sorted, 0.95)),
    max: round2(sorted.at(-1) ?? 0),
  };
};

/// The last reveal of the streaming reply: how much of its source the reveal let through.
const reveal = { received: 0, shown: 0 };
const advance = StreamReveal.prototype.advance;
StreamReveal.prototype.advance = function (this: StreamReveal, text: string, now: number, done: boolean) {
  const shown = advance.call(this, text, now, done);
  if (text.startsWith(REPLY.slice(0, 40))) Object.assign(reveal, { received: text.length, shown });
  return shown;
};

/// Pierre's highlighting ([start, end]): the dev server serves no highlight worker, so Pierre
/// highlights on the main thread, which the app's page never does (highlightPool.ts). `highlighting`
/// holds the outermost synchronous calls, drawing a card or tokenizing its code. WebKit tokenizes
/// inside `render`, in a layout effect (HighlightedCode.tsx), and that time comes off the frame's
/// work. Chromium tokenizes in a promise continuation once its grammar loads, which
/// streaming-text.clock.ts never timed, so nothing comes off. `loading` holds each grammar load,
/// from the call until its promise settles, which tags the frames it spans and takes nothing off.
const highlighting: [number, number][] = [];
const loading: [number, number][] = [];
let highlightDepth = 0;
function timedHighlight<A extends unknown[], R>(body: (...args: A) => R, self: unknown, args: A): R {
  if (highlightDepth > 0) return body.apply(self, args);
  highlightDepth = 1;
  const start = performance.now();
  try {
    return body.apply(self, args);
  } finally {
    highlightDepth = 0;
    highlighting.push([start, performance.now()]);
  }
}
const render = PierreFile.prototype.render;
PierreFile.prototype.render = function (this: PierreFile, ...args: Parameters<typeof render>) {
  return timedHighlight(render, this, args);
};
// Private in Pierre's types; FileRenderer.js calls it through `this` (asyncHighlight).
const renderer = FileRenderer.prototype as unknown as { renderFileWithHighlighter: (...args: unknown[]) => unknown };
const tokenize = renderer.renderFileWithHighlighter;
renderer.renderFileWithHighlighter = function (this: FileRenderer, ...args: unknown[]) {
  return timedHighlight(tokenize, this, args);
};
const initialize = FileRenderer.prototype.initializeHighlighter;
FileRenderer.prototype.initializeHighlighter = function (this: FileRenderer) {
  const start = performance.now();
  return initialize.call(this).finally(() => loading.push([start, performance.now()]));
};
/// Time inside [from, to] that `windows` cover.
const overlap = (windows: [number, number][], from: number, to: number) =>
  windows.reduce((sum, [start, end]) => sum + Math.max(0, Math.min(end, to) - Math.max(start, from)), 0);

/// The first task span no sample has counted.
let nextSpan = 0;

const PROMPT_ID = "live-user";
const ANSWER_ID = "live-answer";
const expanded = new Set<string>();
let show: (rows: AcpmuxRow[], working: boolean) => void = () => {};
/// Draw the running turn's live line under the reply (Debug `agentPane.debug.liveLineBelow`, on in
/// the app), so the end of the turn swaps that line for the turn's footer as the app does.
let lineBelow = false;
/// Turn off the followed view's eased steps (followGlide.ts) to measure the view that steps at once.
let glide = true;

function Pane() {
  const [state, setState] = useState<{ rows: AcpmuxRow[]; working: boolean }>({ rows: history(), working: false });
  const [dock, setDock] = useState<HTMLElement | null>(null);
  show = (rows, working) => setState({ rows, working });
  return (
    <div className="acpmux-shell" data-follow-glide={glide ? undefined : "off"}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(state.rows, expanded, { working: state.working, lineBelow, liveRuns: lineBelow })}
            sessionId="streaming-text"
            working={state.working}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          {/* The docked composer after the first send: the strip's held height over a one-line card. */}
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: 88 }} />
          </form>
        </div>
      </div>
    </div>
  );
}

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });
createRoot(root).render(<Pane />);

/// One sampled display frame.
type Frame = {
  t: number;
  /// The stream has started and not ended.
  live: boolean;
  /// Characters of the reply drawn (its Markdown root's textContent).
  length: number;
  /// Source characters the reveal let through (StreamReveal), and those received but not yet shown.
  shown: number;
  backlog: number;
  /// Layout top (transforms excluded) and height of each block drawn, relative to the reply's root.
  blocks: { tag: string; top: number; height: number; text: string }[];
  /// The reply row's top on screen (transforms included): followed, it only moves up.
  rowTop?: number;
  /// How far the view rests from its end, when it can scroll.
  fromEnd?: number;
  /// Room between the reply's last drawn line and the top of the bottom stack.
  runway?: number;
  /// The transcript's scrollable height and offset: the room under the last row shows in them.
  scrollHeight?: number;
  scrollTop?: number;
  /// Main-thread work since the last sample: the script of every task that ended in between
  /// (streaming-text.clock.ts), less its synchronous Pierre highlighting, and the style and layout
  /// left to do (forced here, before the sampler reads anything).
  scriptMs: number;
  layoutMs: number;
};

const layoutTop = (node: HTMLElement) => {
  let top = 0;
  for (let at: HTMLElement | null = node; at; at = at.offsetParent as HTMLElement | null) top += at.offsetTop;
  return top;
};

/// The bottom of the last line of text drawn in `root`.
function lastLineBottom(root: HTMLElement): number | undefined {
  const last = root.lastElementChild ?? root;
  const walker = document.createTreeWalker(last, NodeFilter.SHOW_TEXT);
  let text: Text | undefined;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) if (node.textContent?.trim()) text = node as Text;
  if (!text) return undefined;
  const range = document.createRange();
  range.selectNodeContents(text);
  const rects = [...range.getClientRects()].filter((rect) => rect.height > 0);
  return rects.at(-1)?.bottom;
}

function sampleFrame(t: number, live: boolean): Frame {
  let scriptMs = 0;
  for (; nextSpan < spans.length; nextSpan += 1) {
    const [start, end] = spans[nextSpan]!;
    scriptMs += end - start - overlap(highlighting, start, end);
  }
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  const layoutStart = performance.now();
  void scroller?.scrollHeight;
  const layoutMs = performance.now() - layoutStart;
  const row = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${ANSWER_ID}"]`);
  const markdown = row?.querySelector<HTMLElement>(".cv-md") ?? undefined;
  const dock = document.querySelector<HTMLElement>(".acpmux-dock");
  const frame: Frame = {
    t,
    live,
    length: 0,
    shown: reveal.shown,
    backlog: reveal.received - reveal.shown,
    blocks: [],
    scriptMs,
    layoutMs,
  };
  if (scroller) Object.assign(frame, { scrollHeight: scroller.scrollHeight, scrollTop: scroller.scrollTop });
  if (scroller && scroller.scrollHeight > scroller.clientHeight)
    frame.fromEnd = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
  if (!row || !markdown) return frame;
  frame.length = markdown.textContent?.length ?? 0;
  frame.rowTop = row.getBoundingClientRect().top;
  const origin = layoutTop(markdown);
  frame.blocks = [...markdown.children].map((child) => {
    const block = child as HTMLElement;
    return {
      tag: block.tagName,
      top: layoutTop(block) - origin,
      height: block.offsetHeight,
      text: (block.textContent ?? "").slice(0, 32),
    };
  });
  const bottom = lastLineBottom(markdown);
  if (dock && bottom !== undefined && frame.fromEnd !== undefined)
    frame.runway = dock.getBoundingClientRect().top - bottom;
  return frame;
}

export type Shift = { t: number; index: number; tag: string; text: string; top: number; height: number };
export type Flip = { t: number; index: number; from: string; to: string; fromText: string; text: string };
export type StreamReport = ReturnType<typeof analyze>;

/// A frame's last block, the one being written: where an event happened.
const tailOf = (frame: Frame) => {
  const last = frame.blocks.at(-1);
  return last ? `${last.tag}#${frame.blocks.length - 1} "${last.text}"` : "";
};
/// Single-frame growth above this many characters reads as a jump, not a flow.
const JUMP_CHARS = 40;
/// A settle step larger than this in one frame reads as a snap: an eased 180 ms move over a line
/// (22.75 px) steps at most about 4 px a frame at 60 Hz.
const SNAP_PX = 8;

function analyze(
  cadence: Cadence,
  deltas: Delta[],
  frames: Frame[],
  start: number,
  longTasks: { t: number; ms: number }[] | null,
  dockHeight: number,
  streamWindowEnd: number,
) {
  const at = (t: number) => round2(t - start);
  const live = frames.filter((frame) => frame.live);
  const intervals = live.slice(1).map((frame, index) => frame.t - live[index]!.t);
  // The intervals Pierre's main-thread highlighting overlaps (only this dev page highlights there).
  const held = live
    .slice(1)
    .map((frame, index) => [...highlighting, ...loading].some(([from, to]) => to > live[index]!.t && from < frame.t));
  const longFrames = live
    .slice(1)
    .flatMap((frame, index) =>
      intervals[index]! > 33
        ? [{ t: at(frame.t), ms: round2(intervals[index]!), tail: tailOf(frame), highlighting: held[index]! }]
        : [],
    );
  // The intervals of frames that waited on no main-thread highlight (only this dev page has one).
  const unhighlighted = intervals.filter((_, index) => !held[index]);
  // Work: what each frame cost the main thread.
  const working = live.slice(1);
  const work = working.map((frame) => frame.scriptMs + frame.layoutMs);
  const heaviest = working.reduce<Frame | undefined>(
    (top, frame) => (top === undefined || frame.scriptMs + frame.layoutMs > top.scriptMs + top.layoutMs ? frame : top),
    undefined,
  );
  // Reveal: what each frame added to the drawn reply, from its first character to the stream's end.
  const first = live.findIndex((frame) => frame.length > 0);
  const growth: number[] = [];
  const revealed: number[] = [];
  const jumps: { t: number; added: number; tail: string }[] = [];
  let stalls = 0;
  for (let index = Math.max(1, first); first >= 0 && index < live.length; index += 1) {
    const frame = live[index]!;
    const added = frame.length - live[index - 1]!.length;
    growth.push(added);
    revealed.push(frame.shown - live[index - 1]!.shown);
    if (frame.shown <= live[index - 1]!.shown && frame.backlog > 0) stalls += 1;
    if (added > JUMP_CHARS || added < 0) jumps.push({ t: at(frame.t), added, tail: tailOf(frame) });
  }
  // Layout above the tail: a block that was already not the last one moved or changed height; a block
  // drawn at an index another tag held.
  const shifts: Shift[] = [];
  const flips: Flip[] = [];
  for (let index = 1; index < frames.length; index += 1) {
    const before = frames[index - 1]!.blocks;
    const now = frames[index]!.blocks;
    const t = at(frames[index]!.t);
    for (let block = 0; block < Math.min(before.length, now.length); block += 1) {
      const was = before[block]!;
      const is = now[block]!;
      if (was.tag !== is.tag) {
        flips.push({ t, index: block, from: was.tag, to: is.tag, fromText: was.text, text: is.text });
        continue;
      }
      if (block >= before.length - 1 || block >= now.length - 1) continue;
      const top = is.top - was.top;
      const height = is.height - was.height;
      if (Math.abs(top) > 0.5 || Math.abs(height) > 0.5)
        shifts.push({ t, index: block, tag: is.tag, text: is.text, top: round2(top), height: round2(height) });
    }
  }
  // Pin: while the view follows (nothing here scrolls it away), it rests at its end, and the reply only
  // ever moves up.
  const followed = frames.filter((frame) => frame.fromEnd !== undefined);
  const bounces: { t: number; down: number }[] = [];
  let rose = false;
  for (let index = 1; index < frames.length; index += 1) {
    const before = frames[index - 1]!.rowTop;
    const now = frames[index]!.rowTop;
    if (before === undefined || now === undefined) continue;
    if (now < before - 0.5) rose = true;
    else if (now > before + 0.5 && rose) bounces.push({ t: at(frames[index]!.t), down: round2(now - before) });
  }
  // Runway: the reply's last line over the bottom stack; below zero it is drawn under the stack.
  const runwayFrames = live.filter((frame) => frame.runway !== undefined);
  const runways = runwayFrames.map((frame) => frame.runway!);
  const lowest = runwayFrames.reduce<Frame | undefined>(
    (low, frame) => (low === undefined || frame.runway! < low.runway! ? frame : low),
    undefined,
  );
  const under = runwayFrames.filter((frame) => frame.runway! < 0);
  // Settle: from the last frame that drew the reply growing to the end of the window, the reply's
  // row should hold still or ease, never jump. A snap is one frame moving it more than SNAP_PX; a
  // reversal is its top moving down after it rose (the room under it given back at once).
  let lastGrowth = 0;
  for (let index = 1; index < frames.length; index += 1)
    if (frames[index]!.length !== frames[index - 1]!.length) lastGrowth = index;
  const settleMoves: { t: number; px: number }[] = [];
  for (let index = Math.max(1, lastGrowth); index < frames.length; index += 1) {
    const before = frames[index - 1]!.rowTop;
    const now = frames[index]!.rowTop;
    if (before === undefined || now === undefined || Math.abs(now - before) <= 0.5) continue;
    settleMoves.push({ t: at(frames[index]!.t), px: round2(now - before) });
  }
  // Follow steps: how far the reply's row moves on screen from one frame to the next while it
  // streams. A followed view that takes each new line at once moves it a whole line in one frame.
  const steps: number[] = [];
  for (let index = 1; index < live.length; index += 1) {
    const before = live[index - 1]!.rowTop;
    const now = live[index]!.rowTop;
    if (before === undefined || now === undefined || Math.abs(now - before) <= 0.5) continue;
    steps.push(Math.abs(now - before));
  }
  // Bottom-edge reversals over the whole run: the reply's top, which a followed view only lifts,
  // coming back down by more than half a pixel in one frame.
  const reversals = bounces.length;
  return {
    cadence,
    chars: REPLY.length,
    deltas: deltas.length,
    streamMs: round2(deltas.at(-1)?.at ?? 0),
    dockHeight: round2(dockHeight),
    frames: {
      count: live.length,
      over16_7ms: intervals.filter((ms) => ms > 16.7).length,
      over33ms: intervals.filter((ms) => ms > 33).length,
      over50ms: intervals.filter((ms) => ms > 50).length,
      intervalMs: stats(intervals),
      longFrames: longFrames.slice(0, 20),
      highlighting: held.filter(Boolean).length,
      unhighlightedIntervalMs: stats(unhighlighted),
      // Pierre's main-thread highlighting while the reply streamed: draws and tokenizing, and loads.
      highlights: [
        ...highlighting.map(([from, to]) => ({ kind: "draw", from, to })),
        ...loading.map(([from, to]) => ({ kind: "load", from, to })),
      ]
        .filter(({ to }) => to > start)
        .map(({ kind, from, to }) => ({ kind, t: at(from), ms: round2(to - from) })),
    },
    work: {
      frames: work.length,
      scriptMs: stats(working.map((frame) => frame.scriptMs)),
      layoutMs: stats(working.map((frame) => frame.layoutMs)),
      totalMs: stats(work),
      heaviest: heaviest && {
        t: at(heaviest.t),
        scriptMs: round2(heaviest.scriptMs),
        layoutMs: round2(heaviest.layoutMs),
        tail: tailOf(heaviest),
      },
    },
    longTasks: longTasks && {
      count: longTasks.length,
      maxMs: round2(Math.max(0, ...longTasks.map((task) => task.ms))),
      totalMs: round2(longTasks.reduce((sum, task) => sum + task.ms, 0)),
      tasks: longTasks.slice(0, 20).map((task) => ({ t: at(task.t), ms: round2(task.ms) })),
      duringStream: longTasks
        .filter((task) => task.t >= start && task.t < streamWindowEnd && task.ms > 50)
        .map((task) => ({ t: at(task.t), ms: round2(task.ms) })),
    },
    reveal: {
      // Drawn: the reply's textContent. A closing fence keeps its plain card under the highlighted one
      // while that fades in (StreamingCode.tsx CodeHandoff), so the code counts twice for a moment.
      charsPerFrame: stats(growth),
      // Source: the characters the reveal let through (StreamReveal.advance); stalls count frames
      // where it let none through while some were waiting.
      sourceCharsPerFrame: stats(revealed),
      sourceMaxJump: Math.max(0, ...revealed),
      zeroGrowthFrames: growth.filter((added) => added <= 0).length,
      stalls,
      maxJump: Math.max(0, ...growth),
      shrinks: growth.filter((added) => added < 0).length,
      jumpEvents: jumps.slice(0, 20),
    },
    layout: {
      shifts: shifts.length,
      flips: flips.length,
      shiftEvents: shifts.slice(0, 40),
      flipEvents: flips.slice(0, 40),
      blocks:
        frames
          .at(-1)
          ?.blocks.map((block) => block.tag)
          .join(" ") ?? "",
    },
    pin: {
      maxFromEnd: round2(Math.max(0, ...followed.map((frame) => frame.fromEnd!))),
      framesOffEnd: followed.filter((frame) => frame.fromEnd! > 4).length,
      bounces: bounces.length,
      bounceEvents: bounces.slice(0, 40),
    },
    follow: {
      moving: steps.length,
      ...stats(steps),
      overSnap: steps.filter((px) => px > SNAP_PX).length,
    },
    settle: {
      moves: settleMoves.length,
      maxMovePx: round2(Math.max(0, ...settleMoves.map((move) => Math.abs(move.px)))),
      snaps: settleMoves.filter((move) => Math.abs(move.px) > SNAP_PX).length,
      reversals,
      moveEvents: settleMoves.slice(0, 40),
    },
    runway: {
      frames: runways.length,
      ...stats(runways),
      min: lowest ? round2(lowest.runway!) : 0,
      minAt: lowest ? { t: at(lowest.t), tail: tailOf(lowest) } : undefined,
      framesUnderDock: under.length,
      underDock: under
        .slice(0, 20)
        .map((frame) => ({ t: at(frame.t), px: round2(frame.runway!), tail: tailOf(frame) })),
    },
  };
}

const frameTime = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

async function run({
  cadence,
  seed = 7,
  settleMs = 1_000,
  liveLine = false,
  eased = true,
}: {
  cadence: Cadence;
  seed?: number;
  settleMs?: number;
  /// Draw the live line under the reply, as the app does by default.
  liveLine?: boolean;
  /// Ease the followed view's steps (followGlide.ts), as the app does.
  eased?: boolean;
}): Promise<StreamReport> {
  lineBelow = liveLine;
  glide = eased;
  const base = history();
  const prompt: AcpmuxRow = {
    id: PROMPT_ID,
    version: 1,
    at: 100_000,
    kind: "user",
    text: "Why does the relay fall over?",
  };
  await loadHighlightedCode();
  show([...base, prompt], true);
  for (let index = 0; index < 30; index += 1) await frameTime();

  const deltas = schedule(REPLY, cadence, seed);
  let text = "";
  let version = 0;
  let streaming = true;
  let ended = false;
  const rows = (summary: boolean): AcpmuxRow[] => [
    ...base,
    prompt,
    { id: ANSWER_ID, version, at: 100_001, kind: "assistant", text, streaming },
    ...(summary
      ? [{ id: "live-end", version: 1, at: 120_000, kind: "turnSummary", status: "completed" } as AcpmuxRow]
      : []),
  ];
  // direct.ts: every event lands in the client's rows; one snapshot goes out per display frame.
  let scheduled = false;
  const emit = () => {
    if (scheduled) return;
    scheduled = true;
    nextFrame(() => {
      scheduled = false;
      const snapshot = rows(ended);
      saveSnapshot({ type: "snapshot", rows: snapshot } as unknown as AcpmuxSnapshot);
      show(snapshot, !ended);
    });
  };

  const frames: Frame[] = [];
  let live = false;
  let sampling = true;
  const longTasks: { t: number; ms: number }[] | null = PerformanceObserver.supportedEntryTypes?.includes("longtask")
    ? []
    : null;
  const observer = longTasks
    ? new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) if (sampling) longTasks.push({ t: entry.startTime, ms: entry.duration });
      })
    : undefined;
  observer?.observe({ type: "longtask", buffered: false });
  const tick = (t: number) => {
    if (!sampling) return;
    frames.push(sampleFrame(t, live));
    untimedFrame(tick);
  };
  untimedFrame(tick);
  await frameTime();

  const start = performance.now();
  const done = new Promise<void>((resolve) => {
    live = true;
    deltas.forEach((delta, index) =>
      setTimeout(
        () => {
          text += delta.text;
          version += 1;
          emit();
          if (index !== deltas.length - 1) return;
          // turn_result: the segment stops streaming (a new version) and the summary comes in.
          version += 1;
          streaming = false;
          ended = true;
          emit();
          resolve();
        },
        Math.max(0, start + delta.at - performance.now()),
      ),
    );
  });
  await done;
  // The reveal drains what is left (StreamReveal.finishMs) before the stream counts as drawn.
  // fixed-wait: the drain's frames are sampled; its length is StreamReveal.finishMs of wall time
  await new Promise((resolve) => setTimeout(resolve, StreamReveal.finishMs + 50));
  live = false;
  // fixed-wait: the settle window is sampled for any jump after the stream; the window is the test
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  const sampleEnd = performance.now();
  if (observer && longTasks) {
    for (const entry of observer.takeRecords()) longTasks.push({ t: entry.startTime, ms: entry.duration });
  }
  sampling = false;
  observer?.disconnect();
  const dock = document.querySelector<HTMLElement>(".acpmux-dock")?.getBoundingClientRect().height ?? 0;
  return analyze(cadence, deltas, frames, start, longTasks, dock, sampleEnd);
}

(window as unknown as { __streamingText: { run: typeof run } }).__streamingText = { run };
