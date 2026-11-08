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

type PaneState = { rows: AcpmuxRow[]; working: boolean; sends: number; card: number };
let show: (next: Partial<PaneState>) => void = () => {};

function Pane() {
  const [state, setState] = useState<PaneState>({ rows: history(), working: false, sends: 0, card: CARD_DRAFT });
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
};

const samples: Sample[] = [];
let phase: Phase = "idle";
let sampling = false;

// The frame callback resizes a sentinel; its ResizeObserver runs after this frame's layout, after
// every other frame callback (React's commits, the follow motion's step), before paint.
const sentinel = document.createElement("div");
Object.assign(sentinel.style, { position: "fixed", left: "0", top: "0", height: "1px", visibility: "hidden" });
document.body.append(sentinel);
let frameAt = 0;
let toggle = false;
new ResizeObserver(() => {
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
  });
}).observe(sentinel);
const tick = (t: number) => {
  frameAt = t;
  toggle = !toggle;
  sentinel.style.width = toggle ? "2px" : "1px";
  requestAnimationFrame(tick);
};
requestAnimationFrame(tick);

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
}: {
  scenario?: Scenario;
  chars?: number;
  everyMs?: number;
  settleMs?: number;
}) {
  await loadHighlightedCode();
  // fixed-wait: the history's rows measure over the first frames
  await wait(400);
  samples.length = 0;
  sampling = true;
  // fixed-wait: the frames before the turn are sampled as its rest
  await wait(100);
  // fixed-wait: the scripted turn is a socket's events on its own clock; the frames sampled are the measurement
  await playScriptedTurn(scenario, {
    show,
    frame: nextFrame,
    step: (name) => (phase = name),
    chars,
    everyMs,
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
