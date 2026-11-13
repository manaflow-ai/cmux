// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A send and a fast streamed reply as the agent pane draws them (App.tsx), for the 120 Hz motion
// check (send-stream-motion.test.ts). Leo, 2026-11-07: "When it comes to sending messages, I feel
// like the jump, the jolt is a bit too jarring ... the way the messages actually stream through ...
// can be made a lot smoother ... what is satisfying at 120 hertz? That's what we want to aim at."
//
// The real VirtualTranscript over a chat's history, followed at its latest row, with a stand-in for
// the docked composer over its foot (as streaming-text.harness.tsx draws it). `run()` plays one
// scripted turn on timers, as a socket's events land: the reader sends (the composer's card shrinks
// from three lines to one in the same commit, `sends` counts one), acpmux's echo brings the prompt's
// row and the running turn's live line, then the reply streams fast (a Markdown reply with headings,
// lists, a code block and a table, 24 characters every 16 ms: 1,500 a second, about 20 lines) and the turn ends with its summary.
//
// The page draws only when the test begins a frame (Chromium's BeginFrame control, one every 8.33 ms
// of wall time), so its frames are a 120 Hz display's. Each frame is sampled after its layout, before
// it paints (a ResizeObserver on a sentinel the frame callback resizes): the thread's visual top (its
// box with the follow motion's `translate`), that translate, the scroll offset and how far it rests
// from the end. The URL picks the follow motion's arm (`?arm=`), the host's motion switch
// (`?motion=off`) and the frames' own clock for the page (`?clock=frames`, frameClock.ts).
// First: with `?clock=frames` the page's timers and clock follow the drawn frames (frameClock.ts).
import "./frameClock";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { loadHighlightedCode } from "../../src/agent-session/acpmux/conversation/codeBlockModel";
import { nextFrame } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { LIVE_THINKING, turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { history, REPLY } from "../../src/agent-session/acpmux/conversation/streamingTextFixture";
import {
  ARRIVAL_QUIET_MS,
  CARD_DRAFT,
  CARD_EMPTY,
  playScriptedTurn,
  SCRIPTED_ANSWER_ID as ANSWER_ID,
  SCRIPTED_PROMPT_ID,
  TOGGLE_CALL_ID,
  type ScriptedTurn,
} from "../../src/agent-session/acpmux/conversation/scriptedTurn";
import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/markdownField.css";

const query = new URLSearchParams(location.search);
const arm = query.get("arm");
// `liveTurnWork=runs`: the arm of live-turn-work for a test of a finished run in a running turn
// (test/support/liveTurnRuns.ts). This page loads when open120Hz makes it, before an init script can run.
const liveTurnWork = query.get("liveTurnWork");
if (arm || liveTurnWork)
  globalThis.cmuxExperiments = {
    ...(arm ? { "follow-motion": arm } : {}),
    ...(liveTurnWork ? { "live-turn-work": liveTurnWork } : {}),
  };
if (query.get("motion") === "off") {
  document.documentElement.dataset.agentMotion = "off";
  document.documentElement.dataset.cmuxMotion = "off";
}

const expanded = new Set<string>();
/// `?history=N`: the chat's history has N finished turns (three rows each), 7 by default.
const historyTurns = Number(query.get("history")) || undefined;

type PaneState = { rows: AcpmuxRow[]; working: boolean; sends: number; card: number };
let show: (next: Partial<PaneState>) => void = () => {};

function Pane() {
  const [state, setState] = useState<PaneState>({
    rows: history(historyTurns),
    working: false,
    sends: 0,
    card: CARD_DRAFT,
  });
  const [dock, setDock] = useState<HTMLElement | null>(null);
  show = (next) => setState((now) => ({ ...now, ...next }));
  return (
    <div className="acpmux-shell">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(state.rows, expanded, { working: state.working })}
            sessionId="send-stream-motion"
            working={state.working}
            sends={state.sends}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: state.card }} />
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

/// The step of the scripted turn a frame was drawn in.
export type Phase = string;
export type Sample = {
  /// The frame's time (rAF), ms.
  t: number;
  phase: Phase;
  /// The thread's visual top in the viewport, px (scroll offset and translate both move it).
  top: number;
  /// The follow motion's translate on the thread, px (how far the drawn rows trail their layout).
  lag: number;
  scrollTop: number;
  /// How far the scroll offset rests from the scroller's end, px.
  fromEnd: number;
  /// How far the reply's newest line ends over the composer card's top, px (negative: under it).
  tail: number;
  /// The reply's text drawn this frame (every segment), in characters.
  length: number;
  /// With `?rows=1` (turn-transition-jumps.test.ts): every mounted row.
  rows?: RowSample[];
  /// With `?rows=1`: the composer card's top in the viewport, px.
  composer?: number;
  /// With `?rows=1`: the scroller's lower edge in the viewport, px.
  viewBottom?: number;
  /// With `?rows=1`, once the tool-toggle turn's call is drawn: its line's top in the viewport (px),
  /// whether it is open, and its details' box: top and height as drawn this frame (0 when none).
  line?: { top: number; open: boolean; bodyTop: number; body: number };
  /// When the frame's step began (the scripted event that named it, on the page's clock), ms.
  eventAt: number;
  /// When the reader's scripted wheel landed, once it has (`run`'s `wheel`), ms.
  wheeledAt?: number;
  /// When the reader scrolled back down to the latest row, once they have (`wheel.backMs`), ms.
  backAt?: number;
  /// Finite animations running this frame, anywhere in the transcript (a looping shimmer is no motion).
  animations: number;
  /// Animations started since the run began (CSS animations and Web Animations), cumulative.
  started: number;
};

/// One drawn row in a frame: its id, its box in the viewport, its ink's opacity (the row's and its
/// presentation child's, as drawn this frame) and whether an animation runs on it or inside it.
export type RowSample = {
  id: string;
  top: number;
  height: number;
  opacity: number;
  animating: boolean;
  /// Whether the row's box crosses the scroller's view.
  inView: boolean;
  /// Whether a finite animation runs on it or inside it (a looping shimmer is not counted).
  moving: boolean;
  /// The row's first words, for the report.
  text: string;
  /// The row's top in the thread's layout, px: where it lies in the thread, no translate.
  layoutTop?: number;
  /// How far a translate on the row draws it from its layout this frame (a fold's or a glide's), px.
  offset?: number;
  /// How much of the row's foot a clip-path cuts off this frame (its bottom inset), px; 0 with none.
  clip?: number;
};

/// The bottom inset of a computed `clip-path: inset(...)`, px (0 for none or another shape). The
/// computed value drops a side that repeats another: one to four lengths, as a margin has.
function bottomInset(clipPath: string): number {
  const inside = /^inset\(([^)]*)\)/.exec(clipPath)?.[1];
  if (!inside) return 0;
  const sides = inside.trim().split(/\s+/);
  return Math.max(0, Number.parseFloat(sides[2] ?? sides[0] ?? "") || 0);
}

const sampleRows = query.get("rows") === "1";
/// `?rows=end` (send-stream-motion.test.ts): the rows only from the turn's end on, on the frame's one
/// sampler, so the frames before it read as they always did; the frame before the end gets its rows
/// as the end step begins (nothing has drawn since that frame).
const rowsAtEnd = query.get("rows") === "end";
const endPhase = (name: string) => name === "end" || name === "after";
// `?tailGlide=`: how the rows under a change move (tailGlide.ts looks), for the arms' numbers.
const tailLook = query.get("tailGlide");
if (tailLook) document.documentElement.setAttribute("data-tail-glide", tailLook);
// `?foldLook=`: how a reader's toggle folds (fold.ts FoldLook), for the looks' numbers.
const foldLookParam = query.get("foldLook");
if (foldLookParam) document.documentElement.setAttribute("data-fold-look", foldLookParam);

/// The rows mounted this frame (RowSample's fields).
function rowSamples(scroller: HTMLElement, thread: HTMLElement): RowSample[] {
  const view = scroller.getBoundingClientRect();
  const animated = new Set<Element>();
  const moving = new Set<Element>();
  for (const animation of document.getAnimations()) {
    if (animation.playState !== "running") continue;
    const target = (animation.effect as KeyframeEffect | null)?.target;
    const row = target instanceof Element ? target.closest(".acpmux-row") : null;
    if (!row) continue;
    animated.add(row);
    if (finite(animation)) moving.add(row);
  }
  const out: RowSample[] = [];
  for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
    const box = row.getBoundingClientRect();
    if (box.height === 0) continue;
    const style = getComputedStyle(row);
    let opacity = Number.parseFloat(style.opacity);
    const offset = style.translate === "none" ? 0 : Number.parseFloat(style.translate.split(" ")[1] ?? "") || 0;
    const inner =
      row.querySelector<HTMLElement>(".acpmux-row__message-presentation") ?? row.firstElementChild?.nextElementSibling;
    if (inner instanceof HTMLElement) opacity *= Number.parseFloat(getComputedStyle(inner).opacity);
    out.push({
      id: row.dataset.rowId!,
      top: box.top,
      height: box.height,
      opacity,
      animating: animated.has(row),
      moving: moving.has(row),
      inView: box.bottom > view.top && box.top < view.bottom,
      text: (row.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 48),
      layoutTop: row.offsetTop - (row.offsetParent === thread ? 0 : thread.offsetTop),
      offset,
      clip: bottomInset(style.clipPath),
    });
  }
  return out;
}

/// The tool-toggle turn's call line and its details this frame (Sample `line`).
function lineSample(): Sample["line"] {
  const line = document.querySelector<HTMLElement>(`[data-tool-id="${TOGGLE_CALL_ID}"][aria-expanded]`);
  if (!line) return undefined;
  const body = line.closest(".acpmux-row")?.querySelector<HTMLElement>(".cv-anchored-collapse");
  const box = body?.getBoundingClientRect();
  return {
    top: line.getBoundingClientRect().top,
    open: line.getAttribute("aria-expanded") === "true",
    bodyTop: box?.top ?? 0,
    body: box?.height ?? 0,
  };
}

/// Whether an animation ends on its own (a looping shimmer never does, and is no motion).
const finite = (animation: Animation) => Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Infinity);
/// Animations started since the run began: every CSS animation, and every Web Animation.
let started = 0;
document.addEventListener("animationstart", () => (started += 1), true);
const animate = Element.prototype.animate;
Element.prototype.animate = function (this: Element, ...args: Parameters<Element["animate"]>) {
  started += 1;
  return animate.apply(this, args);
};

const samples: Sample[] = [];
let phase: Phase = "idle";
let eventAt = 0;
/// When the reader's scripted wheel landed (`run`'s `wheel`), on the page's clock.
let wheeledAt: number | undefined;
/// When the reader scrolled back down to the latest row (`run`'s `wheel.backMs`).
let backAt: number | undefined;
let sampling = false;

// The frame callback resizes a sentinel; its ResizeObserver runs after this frame's layout, after
// every other frame callback (React's commits, the follow motion's step), before paint.
const sentinel = document.createElement("div");
Object.assign(sentinel.style, { position: "fixed", left: "0", top: "0", height: "1px", visibility: "hidden" });
document.body.append(sentinel);
let frameAt = 0;
let toggle = false;
const sampleFrame = () => {
  if (!sampling) return;
  const thread = document.querySelector<HTMLElement>(".acpmux-thread");
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!thread || !scroller) return;
  const lag = Number.parseFloat(getComputedStyle(thread).translate.split(" ")[1] ?? "") || 0;
  let length = 0;
  for (const answer of document.querySelectorAll<HTMLElement>(`.acpmux-row[data-row-id^="${ANSWER_ID}"] .cv-md`))
    length += answer.textContent?.length ?? 0;
  // The reply's newest drawn line, over the composer card's top (the strip's held room over the
  // card is clear): its last text's last line box.
  let bottom = Number.NaN;
  const answers = document.querySelectorAll<HTMLElement>(`.acpmux-row[data-row-id^="${ANSWER_ID}"] .cv-md`);
  const newest = answers[answers.length - 1];
  if (newest) {
    const walker = document.createTreeWalker(newest, NodeFilter.SHOW_TEXT);
    let text: Text | undefined;
    for (let node = walker.nextNode(); node; node = walker.nextNode())
      if (node.textContent?.trim()) text = node as Text;
    if (text) {
      const range = document.createRange();
      range.selectNodeContents(text);
      bottom = [...range.getClientRects()].filter((rect) => rect.height > 0).at(-1)?.bottom ?? Number.NaN;
    }
  }
  const dock = document.querySelector<HTMLElement>(".acpmux-composer-box")?.getBoundingClientRect().top ?? 0;
  samples.push({
    tail: dock - bottom,
    t: frameAt,
    phase,
    top: thread.getBoundingClientRect().top,
    lag,
    scrollTop: scroller.scrollTop,
    fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
    length,
    eventAt,
    ...(wheeledAt !== undefined && { wheeledAt }),
    ...(backAt !== undefined && { backAt }),
    animations: document.getAnimations().filter((animation) => animation.playState === "running" && finite(animation))
      .length,
    started,
    ...((sampleRows || (rowsAtEnd && endPhase(phase))) && {
      rows: rowSamples(scroller, thread),
      composer: dock,
      viewBottom: scroller.getBoundingClientRect().bottom,
      line: lineSample(),
    }),
  });
};
// A row sample reads the rows where the frame paints them: its observer comes after the
// transcript's own (made at its mount), which places the rows under a row that grew this frame.
if (!sampleRows) new ResizeObserver(sampleFrame).observe(sentinel);
let lateSampler: ResizeObserver | undefined;
/// `?load=N`: each frame's callback holds the main thread N ms, as a page under heavy load does (a
/// long transcript's commits, other panes): frames miss their slots on the wall clock.
const loadMs = Number(query.get("load")) || 0;
const tick = (t: number) => {
  frameAt = t;
  if (loadMs > 0) {
    const until = performance.now() + loadMs;
    while (performance.now() < until) {
      // busy: the load
    }
  }
  toggle = !toggle;
  sentinel.style.width = toggle ? "2px" : "1px";
  requestAnimationFrame(tick);
};
requestAnimationFrame(tick);

/// A pointer's click on `target` at its middle: press, release and click, as a mouse delivers them, so
/// the transcript's press and click handlers both see it (`moved`: px the pointer travels between
/// press and release, as a hand that drags a little does).
export function clickLine(target: HTMLElement, moved = 0) {
  const box = target.getBoundingClientRect();
  const x = box.left + Math.min(40, box.width / 2);
  const y = box.top + box.height / 2;
  const at = (dx: number) => ({ clientX: x + dx, clientY: y, button: 0, buttons: 1, bubbles: true, cancelable: true });
  target.dispatchEvent(new PointerEvent("pointerdown", { ...at(0), pointerType: "mouse", isPrimary: true }));
  target.dispatchEvent(new MouseEvent("mousedown", { ...at(0), detail: 1 }));
  if (moved) target.dispatchEvent(new PointerEvent("pointermove", { ...at(moved), pointerType: "mouse" }));
  target.dispatchEvent(
    new PointerEvent("pointerup", { ...at(moved), buttons: 0, pointerType: "mouse", isPrimary: true }),
  );
  target.dispatchEvent(new MouseEvent("mouseup", { ...at(moved), buttons: 0, detail: 1 }));
  target.dispatchEvent(new MouseEvent("click", { ...at(moved), buttons: 0, detail: 1 }));
}

/// The tool-toggle turn's click on its call's line (scriptedTurn.ts TOGGLE_CALL_ID), or a 12 px drag
/// across it.
const act = (action: "toggle" | "drag") => {
  const line = document.querySelector<HTMLElement>(`[data-tool-id="${TOGGLE_CALL_ID}"][aria-expanded]`);
  if (line) clickLine(line, action === "drag" ? 12 : 0);
  else console.warn("send-stream-motion: no line to toggle");
};

// fixed-wait: the harness's own pauses, each named where it waits
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export type Scenario = ScriptedTurn;

/// Plays one scripted turn (conversation/scriptedTurn.ts); resolves with every sampled frame once
/// the view settled.
async function run({
  scenario = "send",
  chars = 24,
  everyMs = 16,
  settleMs = 800,
  wheel,
}: {
  scenario?: Scenario;
  chars?: number;
  everyMs?: number;
  settleMs?: number;
  /// The reader wheels up `px` px, `afterMs` after the step `at` begins (row-arrival-settle.test.ts:
  /// their input holds every motion where it is drawn): a wheel event on the transcript, then the
  /// scroll it makes, in one task, as a wheel the page does not cancel scrolls. With `backMs`, the
  /// reader wheels back down to the latest row that long after (chat-scroll-back-still.test.ts).
  wheel?: { at: string; afterMs: number; px: number; backMs?: number };
}) {
  await loadHighlightedCode();
  // fixed-wait: the history's rows measure over the first frames
  await wait(400);
  samples.length = 0;
  started = 0;
  wheeledAt = undefined;
  backAt = undefined;
  if (sampleRows && !lateSampler) (lateSampler = new ResizeObserver(sampleFrame)).observe(sentinel);
  sampling = true;
  // fixed-wait: the frames before the turn are sampled as its rest
  await wait(100);
  // fixed-wait: the scripted turn is a socket's events on its own clock; the frames sampled are the measurement
  await playScriptedTurn(scenario, {
    show,
    frame: nextFrame,
    step: (name) => {
      phase = name;
      if (rowsAtEnd && name === "end" && sampling) {
        const last = samples.at(-1);
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const thread = document.querySelector<HTMLElement>(".acpmux-thread");
        if (last && scroller && thread) last.rows = rowSamples(scroller, thread);
      }
      // A capture driving the page frame by frame (turn-end-stills.test.ts) hears each step.
      (window as unknown as { __onStep?: (name: string) => void }).__onStep?.(name);
      eventAt = performance.now();
      if (wheel?.at === name)
        // fixed-wait: the reader's wheel lands at a scripted point in the step's motion
        setTimeout(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.dispatchEvent(
            new WheelEvent("wheel", { deltaY: -wheel.px, deltaMode: 0, bubbles: true, cancelable: true }),
          );
          scroller.scrollTop -= wheel.px;
          wheeledAt = performance.now();
          if (wheel.backMs !== undefined)
            // fixed-wait: the reader reads where they wheeled to, then wheels back down
            setTimeout(() => {
              const end = scroller.scrollHeight - scroller.clientHeight;
              scroller.dispatchEvent(
                new WheelEvent("wheel", {
                  deltaY: end - scroller.scrollTop,
                  deltaMode: 0,
                  bubbles: true,
                  cancelable: true,
                }),
              );
              scroller.scrollTop = end;
              backAt = performance.now();
            }, wheel.backMs);
        }, wheel.afterMs);
    },
    chars,
    everyMs,
    historyTurns,
    act,
  });
  // fixed-wait: the reveal drains (StreamReveal.finishMs) before the stream counts as drawn
  await wait(400);
  phase = "after";
  // fixed-wait: the settle window is sampled for any move after the stream
  await wait(settleMs);
  sampling = false;
  return samples;
}

/// What `heldFold` did besides its frames, for the test's report.
export type HeldFold = {
  samples: Sample[];
  /// How far up the reader wheeled, px, and when (the page's clock, ms).
  px: number;
  wheeledAt: number;
  /// When the reader clicked the run's line, and the line then: its words, its box, whether it was
  /// closed, and whether it is open at the end.
  clickedAt: number;
  line?: { text: string; top: number; bottom: number; closed: boolean; opened: boolean };
  /// The scroller's box and the composer card's top at the click, px.
  view: { top: number; bottom: number; composer: number };
  /// The turn's rows at the click, in thread order: id, top, height and first words.
  rows: string[];
};

/// How far under the view's end the reader's wheel leaves the live line's foot, px: a small scroll up.
const HELD_FOOT_UNDER_PX = 24;

/// A reader opens a finished run while the running turn's live line is held (held-live-line-fold-
/// browser.test.ts). The turn comes as a socket's events bring it, as `run`'s scripted turns do
/// (scriptedTurn.ts: rows `put` and drawn in the next frame, the replies streamed 24 characters every
/// 16 ms), so the view follows it from the prompt on: a reply streams, three calls run and finish one
/// after another in one row (a finished run, a closed line), a longer reply streams, then, after a
/// rest, one more call starts and, after another rest, finishes. That call's row lands above the live
/// line, so the follow chase draws the thread back and the live line holds still against it
/// (pinnedLiveLine.ts), as in chat-scroll-back-still's `arrive-tool` turn. 16 ms into that chase the
/// reader wheels up, just far enough that the live line's foot goes under the view's end: the line is
/// held where it is drawn. Then they click the first run's line, which is in view over the composer.
/// No experiment arm is set here: the page draws the look the app ships.
async function heldFold({ settleMs = 450 }: { settleMs?: number } = {}): Promise<HeldFold> {
  await loadHighlightedCode();
  // fixed-wait: the history's rows measure over the first frames
  await wait(400);
  samples.length = 0;
  started = 0;
  wheeledAt = undefined;
  backAt = undefined;
  if (sampleRows && !lateSampler) (lateSampler = new ResizeObserver(sampleFrame)).observe(sentinel);
  sampling = true;
  const base = history(historyTurns);
  const paragraphs = REPLY.split("\n\n");
  const prompt = {
    id: SCRIPTED_PROMPT_ID,
    version: 1,
    at: 100_000,
    kind: "user",
    text: "Why does the relay fall over?",
  } as AcpmuxRow;
  /// The turn's rows after the prompt, by id in order; `emit` draws them in the next frame.
  const turn = new Map<string, AcpmuxRow>();
  let version = 0;
  let scheduled = false;
  const put = (row: Omit<AcpmuxRow, "version">) => {
    version += 1;
    turn.set(row.id, { ...row, version } as AcpmuxRow);
  };
  const emit = () => {
    if (scheduled) return;
    scheduled = true;
    nextFrame(() => {
      scheduled = false;
      show({ rows: [...base, prompt, ...turn.values()], working: true });
    });
  };
  const stream = async (id: string, at: number, source: string) => {
    for (let index = 0; index < source.length; index += 24) {
      put({ id, at, kind: "assistant", text: source.slice(0, index + 24), streaming: true });
      emit();
      // fixed-wait: the reply streams 24 characters every 16 ms, as `run`'s does
      await wait(16);
    }
    put({ id, at, kind: "assistant", text: source, streaming: false });
    emit();
  };
  type Call = { kind: "tool"; text: string; tool: { id: string; title: string; kind: string; status: string } };
  const call = (row: string, index: number, title: string, kind: string, status: string): Call => ({
    kind: "tool",
    text: title,
    tool: { id: `${row}-call-${index}`, title, kind, status },
  });
  const activity = (id: string, at: number, items: Call[]) =>
    ({
      id,
      at,
      kind: "activity",
      toolCount: items.length,
      items,
      streaming: items.some((item) => item.tool.status !== "completed"),
    }) as Omit<AcpmuxRow, "version">;
  const step = (name: string) => {
    phase = name;
    eventAt = performance.now();
  };
  // fixed-wait: the frames before the turn are sampled as its rest
  await wait(100);
  step("prompt");
  show({ rows: [...base, prompt], working: true, card: CARD_EMPTY });
  // fixed-wait: the scripted turn is a socket's events on its own clock; the frames sampled are the measurement
  await wait(300);
  step("stream");
  await stream(ANSWER_ID, 100_001, paragraphs[0]!);
  // The first run: each call starts, runs and finishes (scriptedTurn.ts `tool-group`).
  const first: [string, string][] = [
    ["Read relay.ts", "read"],
    ["Grep reconnect", "search"],
    ["Read socket.ts", "read"],
  ];
  const items: Call[] = [];
  for (const [index, [title, kind]] of first.entries()) {
    step(`call-${index + 1}`);
    items.push(call("held-run-a", index, title, kind, "in_progress"));
    put(activity("held-run-a", 100_002, [...items]));
    emit();
    // fixed-wait: the call runs
    await wait(200);
    items[index] = call("held-run-a", index, title, kind, "completed");
    put(activity("held-run-a", 100_002, [...items]));
    emit();
    // fixed-wait: the agent reads the result before its next call
    await wait(100);
  }
  // Two paragraphs: a reply to the reader, never a short note that joins the runs around it
  // (turns.ts `mergeShortNotes`), and tall enough that the first run's line stays over the composer.
  step("segment");
  await stream(`${ANSWER_ID}-2`, 100_010, `${paragraphs[1]!}\n\n${paragraphs[0]!}`);
  // fixed-wait: every motion of the rows that came ends before the next event, as an arrival turn's does
  await wait(ARRIVAL_QUIET_MS);
  step("begin");
  put(activity("held-run-b", 100_011, [call("held-run-b", 0, "Read retry.ts", "read", "in_progress")]));
  emit();
  // fixed-wait: the view rests before the call lands, as an arrival turn's does
  await wait(ARRIVAL_QUIET_MS);
  step("land");
  put(activity("held-run-b", 100_011, [call("held-run-b", 0, "Read retry.ts", "read", "completed")]));
  emit();
  // fixed-wait: the reader's wheel lands 16 ms into the chase, as chat-scroll-back-still's does
  await wait(16);
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const live = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${LIVE_THINKING}"]`);
  const end = scroller.getBoundingClientRect().bottom;
  const px = Math.max(60, Math.ceil(end - (live?.getBoundingClientRect().bottom ?? end)) + HELD_FOOT_UNDER_PX);
  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -px, deltaMode: 0, bubbles: true, cancelable: true }));
  scroller.scrollTop -= px;
  wheeledAt = performance.now();
  step("wheel");
  // fixed-wait: the reader reads for a moment before they click; the click, the fold and the frames
  // after it all come before their input goes quiet (userScroll.ts USER_SCROLL_INTENT_MS, 1 s)
  await wait(200);
  step("click");
  const view = scroller.getBoundingClientRect();
  // The topmost closed run line that the reader sees whole.
  const closed = [...document.querySelectorAll<HTMLElement>(".acpmux-row button[data-tool-run]")]
    .filter((each) => each.getAttribute("aria-expanded") === "false" && each.getBoundingClientRect().top >= view.top)
    .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
  const line = closed[0];
  const box = line?.getBoundingClientRect();
  const out: HeldFold = {
    samples,
    px,
    wheeledAt,
    clickedAt: performance.now(),
    ...(line &&
      box && {
        line: { text: (line.textContent ?? "").trim(), top: box.top, bottom: box.bottom, closed: true, opened: false },
      }),
    view: {
      top: view.top,
      bottom: view.bottom,
      composer: document.querySelector<HTMLElement>(".acpmux-composer-box")?.getBoundingClientRect().top ?? 0,
    },
    rows: [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
      .map((row) => ({ row, at: row.getBoundingClientRect() }))
      .sort((a, b) => a.at.top - b.at.top)
      .slice(-8)
      .map(
        ({ row, at }) =>
          `${row.dataset.rowId} top ${at.top.toFixed(1)} height ${at.height.toFixed(1)} "${(row.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 32)}"`,
      ),
  };
  if (line) clickLine(line);
  // fixed-wait: the fold plays and the rows rest; the frames sampled are the measurement
  await wait(settleMs);
  step("after");
  // fixed-wait: the rest after the fold is sampled
  await wait(150);
  sampling = false;
  if (out.line && line) out.line.opened = line.isConnected && line.getAttribute("aria-expanded") === "true";
  return out;
}

(window as unknown as { __sendStream: { run: typeof run; heldFold: typeof heldFold } }).__sendStream = {
  run,
  heldFold,
};
