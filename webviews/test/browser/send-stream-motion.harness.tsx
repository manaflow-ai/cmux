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
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { history } from "../../src/agent-session/acpmux/conversation/streamingTextFixture";
import {
  CARD_DRAFT,
  playScriptedTurn,
  SCRIPTED_ANSWER_ID as ANSWER_ID,
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
if (arm) globalThis.cmuxExperiments = { "follow-motion": arm };
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
};

const sampleRows = query.get("rows") === "1";
// `?tailGlide=`: how the rows under a change move (tailGlide.ts looks), for the arms' numbers.
const tailLook = query.get("tailGlide");
if (tailLook) document.documentElement.setAttribute("data-tail-glide", tailLook);
// `?foldLook=`: how a reader's toggle folds (fold.ts FoldLook), for the looks' numbers.
const foldLookParam = query.get("foldLook");
if (foldLookParam) document.documentElement.setAttribute("data-fold-look", foldLookParam);

/// The rows mounted this frame (RowSample's fields).
function rowSamples(scroller: HTMLElement): RowSample[] {
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
    let opacity = Number.parseFloat(getComputedStyle(row).opacity);
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
    ...(sampleRows && { rows: rowSamples(scroller), composer: dock, line: lineSample() }),
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

(window as unknown as { __sendStream: { run: typeof run } }).__sendStream = { run };
