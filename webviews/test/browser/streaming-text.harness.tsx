// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A streaming reply as the agent pane draws it (App.tsx): the real VirtualTranscript over a chat's
// history, with a stand-in for the bottom stack laid over its foot (bottomStack.css) as the docked
// composer is, after the first send (the strip's 46 px placeholder over a one-line card). A long
// Markdown reply arrives in deltas on timers, as a socket's do, at Claude's cadence (16 characters
// every 50 ms) or Codex's (runs of tokens a few ms apart, then 100-500 ms pauses, from a seeded
// PRNG). Each delta grows the row's text and bumps its version, and one snapshot draws per display
// frame however many deltas land in it (direct.ts `emitInFrame` with main.tsx's `nextFrame`); the
// app also stores each snapshot in sessionStorage, which this does too. The stream ends as a turn
// does: the row stops streaming and the turn's summary row comes in.
//
// `window.__streamingText.run({ cadence })` streams the reply once and samples every display frame
// while it streams and for a second after: frame intervals and long tasks, how much of the reply
// shows on each frame, where each drawn block of the reply sits, how far the view rests from its
// end, and the room between the reply's last line and the bottom stack. It resolves with a report
// (streaming-text-frames.test.ts reads it).
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { nextFrame } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { percentile, round2 } from "../../src/agent-session/acpmux/perf";
import { StreamReveal } from "../../src/agent-session/acpmux/streamReveal";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
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

/// A reply of about 5,000 characters with every block a long answer has.
export const REPLY = [
  "I read the retry path end to end, from the socket wrapper down to the queue that replays requests after a " +
    "reconnect. The short version is that every client waits the same fixed delay before it tries again, so when " +
    "the relay restarts, a few thousand of them come back in the same second and knock it over again. The fix is " +
    "small, but it touches three places, so here is what changes and why.",
  "",
  "I also looked at the last three incidents in the relay's dashboard. Each one starts the same way: a deploy " +
    "restarts the relay, the open sockets close within a few hundred milliseconds of each other, and the first " +
    "wave of reconnects arrives before the new process has finished loading its routing table. The relay answers " +
    "that wave with errors, every client schedules its next try for exactly the same moment, and the cycle repeats " +
    "until someone scales the relay up by hand.",
  "",
  "## What happens today",
  "",
  "- `RetryPolicy.next()` returns a fixed 500 ms delay for every attempt, with no cap on the attempt count.",
  "- The socket wrapper resets the attempt counter on **every** open, even one that closes again at once.",
  "- Queued requests replay in one burst as soon as the socket opens, before the relay has said it is ready.",
  "- Nothing records why a connection closed, so the logs cannot tell a restart from a network drop.",
  "- The health check shares the same policy, which means it hammers the relay just as hard as the clients.",
  "",
  "## The plan",
  "",
  "1. Replace the fixed delay with exponential backoff and full jitter.",
  "   - Start at 250 ms and double each attempt, capped at 30 seconds.",
  "   - Pick the actual delay uniformly between zero and that ceiling, so a crowd spreads out.",
  "2. Count an open as healthy only after the relay's `ready` frame arrives.",
  "   - A socket that opens and closes within two seconds keeps its attempt count.",
  "   - The counter resets once a request completes on the new connection.",
  "3. Drain the replay queue at a steady rate instead of all at once.",
  "   - Ten requests every 100 ms is plenty for the busiest workspace we measured.",
  "4. Log the close code and reason with each retry, so the next outage is easy to read.",
  "",
  "Here is the new policy. It keeps the same interface, so the call sites do not change:",
  "",
  "```ts",
  "export type RetryOptions = {",
  "  baseMs?: number;",
  "  capMs?: number;",
  "  random?: () => number;",
  "};",
  "",
  "export class RetryPolicy {",
  "  private attempt = 0;",
  "  private readonly baseMs: number;",
  "  private readonly capMs: number;",
  "  private readonly random: () => number;",
  "",
  "  constructor({ baseMs = 250, capMs = 30_000, random = Math.random }: RetryOptions = {}) {",
  "    this.baseMs = baseMs;",
  "    this.capMs = capMs;",
  "    this.random = random;",
  "  }",
  "",
  "  /** The delay before the next attempt: full jitter under an exponential ceiling. */",
  "  next(): number {",
  "    const ceiling = Math.min(this.capMs, this.baseMs * 2 ** this.attempt);",
  "    this.attempt += 1;",
  "    return Math.round(this.random() * ceiling);",
  "  }",
  "",
  "  /** A request completed on the new connection: start over. */",
  "  reset(): void {",
  "    this.attempt = 0;",
  "  }",
  "}",
  "```",
  "",
  "With the defaults, the ceilings and the spread look like this for the first eight attempts:",
  "",
  "| Attempt | Ceiling | Mean delay | Clients per second (of 5,000) |",
  "| --- | ---: | ---: | ---: |",
  "| 1 | 250 ms | 125 ms | 5,000 |",
  "| 2 | 500 ms | 250 ms | 5,000 |",
  "| 3 | 1 s | 500 ms | 5,000 |",
  "| 4 | 2 s | 1 s | 2,500 |",
  "| 5 | 4 s | 2 s | 1,250 |",
  "| 6 | 8 s | 4 s | 625 |",
  "| 7 | 16 s | 8 s | 313 |",
  "| 8 | 30 s | 15 s | 167 |",
  "",
  "By the fourth attempt the relay sees half the load it sees today, and by the sixth it is well under what it " +
    "handles in a normal minute. I have not changed the health check yet: it should get its own policy with a " +
    "longer base delay, and I would rather do that in a separate change once this one has run for a day. If you " +
    "want, I can also add a small test that drives the policy with a seeded random source and checks the " +
    "ceilings in the table above.",
  "",
  "## Rollout",
  "",
  "- Ship the policy behind the existing `relay.retry` setting, defaulting to the new schedule.",
  "- Watch the reconnect rate on the dashboard through the next two relay deploys.",
  "- If the first wave still errors, raise the base delay to 500 ms before touching anything else.",
  "",
  "Nothing here changes the wire protocol, so older clients keep working while the new ones roll out, and the " +
    "relay needs no change of its own. The one visible difference is that a client may now take up to thirty " +
    "seconds to come back after a long outage, which is the point: the relay comes back first.",
].join("\n");

/// The chat's history: enough turns to fill the view, so it opens at its latest line.
function history(): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; turn < 7; turn += 1) {
    rows.push({ id: `h${turn}-user`, version: 1, at: turn * 10_000, kind: "user", text: `Question ${turn}?` });
    rows.push({
      id: `h${turn}-answer`,
      version: 1,
      at: turn * 10_000 + 1,
      kind: "assistant",
      text:
        `History answer ${turn}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down to write the log.",
    });
    rows.push({
      id: `h${turn}-end`,
      version: 1,
      at: turn * 10_000 + 2,
      kind: "turnSummary",
      status: "completed",
      durationMs: 4_000,
    } as AcpmuxRow);
  }
  return rows;
}

export type Cadence = "claude" | "codex";
type Delta = { at: number; text: string };

/// A small seeded PRNG (mulberry32), so a cadence is the same on every run.
function prng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

/// When each delta of `text` arrives, in ms from the first.
export function schedule(text: string, cadence: Cadence, seed = 7): Delta[] {
  const deltas: Delta[] = [];
  if (cadence === "claude") {
    for (let index = 0; index < text.length; index += 16)
      deltas.push({ at: (index / 16) * 50, text: text.slice(index, index + 16) });
    return deltas;
  }
  const random = prng(seed);
  const between = (low: number, high: number) => low + random() * (high - low);
  let at = 0;
  let index = 0;
  while (index < text.length) {
    const tokens = Math.round(between(8, 30));
    for (let token = 0; token < tokens && index < text.length; token += 1) {
      const size = Math.round(between(2, 8));
      deltas.push({ at, text: text.slice(index, index + size) });
      index += size;
      at += between(1, 6);
    }
    at += between(100, 500);
  }
  return deltas;
}

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

const PROMPT_ID = "live-user";
const ANSWER_ID = "live-answer";
const expanded = new Set<string>();
let show: (rows: AcpmuxRow[], working: boolean) => void = () => {};

function Pane() {
  const [state, setState] = useState<{ rows: AcpmuxRow[]; working: boolean }>({ rows: history(), working: false });
  const [dock, setDock] = useState<HTMLElement | null>(null);
  show = (rows, working) => setState({ rows, working });
  return (
    <div className="acpmux-shell">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(state.rows, expanded, { working: state.working })}
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
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  const row = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${ANSWER_ID}"]`);
  const markdown = row?.querySelector<HTMLElement>(".cv-md") ?? undefined;
  const dock = document.querySelector<HTMLElement>(".acpmux-dock");
  const frame: Frame = { t, live, length: 0, shown: reveal.shown, backlog: reveal.received - reveal.shown, blocks: [] };
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

function analyze(
  cadence: Cadence,
  deltas: Delta[],
  frames: Frame[],
  start: number,
  longTasks: { t: number; ms: number }[] | null,
  dockHeight: number,
) {
  const at = (t: number) => round2(t - start);
  const live = frames.filter((frame) => frame.live);
  const intervals = live.slice(1).map((frame, index) => frame.t - live[index]!.t);
  const longFrames = live
    .slice(1)
    .flatMap((frame, index) =>
      intervals[index]! > 33 ? [{ t: at(frame.t), ms: round2(intervals[index]!), tail: tailOf(frame) }] : [],
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
    },
    longTasks: longTasks && {
      count: longTasks.length,
      maxMs: round2(Math.max(0, ...longTasks.map((task) => task.ms))),
      totalMs: round2(longTasks.reduce((sum, task) => sum + task.ms, 0)),
      tasks: longTasks.slice(0, 20).map((task) => ({ t: at(task.t), ms: round2(task.ms) })),
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
}: {
  cadence: Cadence;
  seed?: number;
  settleMs?: number;
}): Promise<StreamReport> {
  const base = history();
  const prompt: AcpmuxRow = {
    id: PROMPT_ID,
    version: 1,
    at: 100_000,
    kind: "user",
    text: "Why does the relay fall over?",
  };
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
      try {
        sessionStorage.setItem("cmux.acpmux.snapshot", JSON.stringify({ rows: snapshot }));
      } catch {
        // As the app: painting goes on without storage.
      }
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
        for (const entry of list.getEntries()) if (live) longTasks.push({ t: entry.startTime, ms: entry.duration });
      })
    : undefined;
  observer?.observe({ type: "longtask", buffered: false });
  const tick = (t: number) => {
    if (!sampling) return;
    frames.push(sampleFrame(t, live));
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
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
  await new Promise((resolve) => setTimeout(resolve, StreamReveal.finishMs + 50));
  live = false;
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  sampling = false;
  observer?.disconnect();
  const dock = document.querySelector<HTMLElement>(".acpmux-dock")?.getBoundingClientRect().height ?? 0;
  return analyze(cadence, deltas, frames, start, longTasks, dock);
}

(window as unknown as { __streamingText: { run: typeof run } }).__streamingText = { run };
