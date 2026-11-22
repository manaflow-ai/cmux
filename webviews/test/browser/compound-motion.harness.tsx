// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The compound motions of the agent pane, one scenario each, for the motion map
// (compound-motion.test.ts). Leo, 2026-11-22: "there are a lot of these possible compound movement
// situations, esp with folds, that i think we can watch for and map out harder to have more cohesive
// animations."
//
// The real VirtualTranscript over a chat's history, followed at its latest row, with a stand-in for
// the docked composer (as send-stream-motion.harness.tsx draws it, plus a prompt field that grows on
// the composer's growth event and a queue card the stack can bring). `run({scenario})` plays one
// scenario on timers, as a socket's events land, and names the step its event starts in. Every frame
// is sampled after its layout, before it paints (a ResizeObserver on a sentinel the frame callback
// resizes): each mounted row's drawn top and the viewport's middle. The URL picks the arm of
// compound-motion (`?arm=transaction|separate`).
import "./frameClock";
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { loadHighlightedCode } from "../../src/agent-session/acpmux/conversation/codeBlockModel";
import { nextFrame } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { REPLY } from "../../src/agent-session/acpmux/conversation/streamingTextFixture";
import {
  CARD_EMPTY,
  playScriptedTurn,
  scriptedHistory,
  SCRIPTED_PROMPT_ID,
  TOGGLE_CALL_ID,
  type ScriptedTurn,
} from "../../src/agent-session/acpmux/conversation/scriptedTurn";
import { FIELD_GROWTH_EVENT, type FieldGrowthDetail } from "../../src/agent-session/acpmux/composer/fieldGrowthEvent";
import { MOTION_MS, MOTION_SETTLE } from "../../src/motion/scale.generated";
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
import { TRANSCRIPT_ROW } from "../../src/agent-session/acpmux/transcriptSelectors";
import { EVENT_STEP, type Scenario } from "../support/compoundMotionReport";

const query = new URLSearchParams(location.search);
const arm = query.get("arm");
if (arm) globalThis.cmuxExperiments = { "compound-motion": arm };
// The page measures the motion itself: a loaded runner never turns the chat's minimal motion on.
document.documentElement.setAttribute("data-chat-motion", "full");

/// One composer line (the field's line box, as scriptedTurn.ts CARD_DRAFT counts it), px.
const LINE = 22.75;
const FIELD_EMPTY = CARD_EMPTY - LINE * 2;
const expanded = new Set<string>();

type PaneState = {
  rows: AcpmuxRow[];
  working: boolean;
  sends: number;
  card: number;
  /// A queue card over the composer, px tall (0: none).
  queue: number;
  /// The stage's width share (1: the whole pane), for the split resize.
  width: number;
};
let show: (next: Partial<PaneState>) => void = () => {};

function Pane() {
  const [now, setState] = useState<PaneState>({
    rows: scriptedHistory(),
    working: false,
    sends: 0,
    card: CARD_EMPTY,
    queue: 0,
    width: 1,
  });
  const [dock, setDock] = useState<HTMLElement | null>(null);
  show = (next) => setState((was) => ({ ...was, ...next }));
  return (
    <div className="acpmux-shell" style={{ width: `${now.width * 100}%` }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(now.rows, expanded, { working: now.working })}
            sessionId="compound-motion"
            working={now.working}
            sends={now.sends}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          {now.queue > 0 && <div className="compound-queue" style={{ height: now.queue }} />}
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box">
              <div className="acpmux-md-field" style={{ height: now.card - CARD_EMPTY + FIELD_EMPTY }} />
              <div style={{ height: CARD_EMPTY - FIELD_EMPTY }} />
            </div>
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

export type RowTop = { id: string; top: number; height: number };
export type Sample = { t: number; phase: string; rows: RowTop[]; middle: number; viewTop: number; viewBottom: number };

const samples: Sample[] = [];
let phase = "idle";
let sampling = false;
const sentinel = document.createElement("div");
Object.assign(sentinel.style, { position: "fixed", left: "0", top: "0", height: "1px", visibility: "hidden" });
document.body.append(sentinel);
let frameAt = 0;
let toggle = false;
let sampler: ResizeObserver | undefined;
const sampleFrame = () => {
  if (!sampling) return;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return;
  const view = scroller.getBoundingClientRect();
  const rows: RowTop[] = [];
  for (const row of scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
    const box = row.getBoundingClientRect();
    if (box.height > 0) rows.push({ id: row.dataset.rowId!, top: box.top, height: box.height });
  }
  samples.push({
    t: frameAt,
    phase,
    rows,
    middle: (view.top + view.bottom) / 2,
    viewTop: view.top,
    viewBottom: view.bottom,
  });
};
const tick = (t: number) => {
  frameAt = t;
  toggle = !toggle;
  sentinel.style.width = toggle ? "2px" : "1px";
  requestAnimationFrame(tick);
};
requestAnimationFrame(tick);

// fixed-wait: the harness's own script, each pause named where it waits
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function clickLine(target: HTMLElement) {
  const box = target.getBoundingClientRect();
  const at = {
    clientX: box.left + Math.min(40, box.width / 2),
    clientY: box.top + box.height / 2,
    button: 0,
    bubbles: true,
    cancelable: true,
  };
  target.dispatchEvent(new PointerEvent("pointerdown", { ...at, buttons: 1, pointerType: "mouse", isPrimary: true }));
  target.dispatchEvent(new MouseEvent("mousedown", { ...at, buttons: 1, detail: 1 }));
  target.dispatchEvent(new PointerEvent("pointerup", { ...at, buttons: 0, pointerType: "mouse", isPrimary: true }));
  target.dispatchEvent(new MouseEvent("mouseup", { ...at, buttons: 0, detail: 1 }));
  target.dispatchEvent(new MouseEvent("click", { ...at, buttons: 0, detail: 1 }));
}

/// The composer field grows by `lines` on the field's own motion and tells the transcript
/// (composer/fieldGrowth.ts dispatches the same event as its motion starts).
function growField(lines: number) {
  const field = document.querySelector<HTMLElement>(".acpmux-md-field")!;
  const from = field.getBoundingClientRect().height;
  const to = from + lines * LINE;
  const duration = MOTION_MS.standard;
  const animation = field.animate([{ height: `${from}px` }, { height: `${to}px` }], {
    duration,
    easing: MOTION_SETTLE,
  });
  field.style.height = `${to}px`;
  const detail: FieldGrowthDetail = { to, easing: MOTION_SETTLE, duration, animation };
  field.dispatchEvent(new CustomEvent(FIELD_GROWTH_EVENT, { bubbles: true, detail }));
}

const SCRIPTED: Partial<Record<Scenario, ScriptedTurn>> = {
  steer: "steer-tools",
  "fold-stream": "tool-toggle",
  "resize-fold": "tool-toggle",
  "subagent-land": "arrive-subagent",
  "recap-end": "tools",
};

/// A send of `lines` lines from the latest row: the card clears to one line as `sends` counts one,
/// acpmux's echo brings the prompt's row and the live line 30 ms later (scriptedTurn.ts `send`).
async function send(lines: number) {
  show({ card: CARD_EMPTY + (lines - 1) * LINE });
  // fixed-wait: the draft's height settles before the send
  await wait(300);
  phase = "send";
  show({ sends: 1, card: CARD_EMPTY });
  // fixed-wait: the echo's round trip, as scriptedTurn.ts plays it
  await wait(30);
  const text = Array.from({ length: lines }, (_, index) => `Line ${index + 1} of the prompt.`).join("\n");
  show({
    rows: [...scriptedHistory(), { id: SCRIPTED_PROMPT_ID, version: 1, at: Date.now(), kind: "user", text }],
    working: true,
  });
  // fixed-wait: the window after the send is sampled
  await wait(700);
}

/// A reply streams (24 characters every 16 ms) and `event` lands a third of the way in.
async function streamWith(name: string, event: () => void) {
  const base = scriptedHistory();
  const prompt: AcpmuxRow = {
    id: SCRIPTED_PROMPT_ID,
    version: 1,
    at: Date.now(),
    kind: "user",
    text: "Why does the relay fall over?",
  };
  show({ rows: [...base, prompt], working: true });
  // fixed-wait: the prompt's rows settle before the stream
  await wait(300);
  phase = "stream";
  const text = REPLY.split("\n\n").slice(0, 8).join("\n\n");
  let version = 1;
  for (let index = 0; index < text.length; index += 24) {
    if (index >= 24 * 25 && phase === "stream") {
      phase = name;
      event();
    }
    version += 1;
    const reply: AcpmuxRow = {
      id: "live-answer",
      version,
      at: Date.now(),
      kind: "assistant",
      text: text.slice(0, index + 24),
      streaming: true,
    };
    nextFrame(() => show({ rows: [...base, prompt, reply] }));
    // fixed-wait: the stream's cadence, a socket's deltas
    await wait(16);
  }
  // fixed-wait: the window after the stream is sampled
  await wait(500);
}

async function run({ scenario }: { scenario: Scenario }) {
  await loadHighlightedCode();
  // fixed-wait: the history's rows measure over the first frames
  await wait(400);
  samples.length = 0;
  if (!sampler) (sampler = new ResizeObserver(sampleFrame)).observe(sentinel);
  sampling = true;
  phase = "idle";
  // fixed-wait: the frames before the scenario are sampled as its rest
  await wait(100);
  const scripted = SCRIPTED[scenario];
  let clicked = false;
  if (scenario === "control") {
    phase = "rest";
    // fixed-wait: nothing happens; the control's window
    await wait(600);
  } else if (scenario.startsWith("send-")) await send(Number(scenario.slice("send-".length)));
  else if (scenario === "growth-stream") await streamWith("grow", () => growField(2));
  else if (scenario === "stack-stream") await streamWith("queue", () => show({ queue: LINE * 3 }));
  else if (scripted)
    await playScriptedTurn(scripted, {
      show,
      frame: nextFrame,
      step: (name) => {
        phase = name;
      },
      act: () => {
        // Only the first click (the toggle turn clicks five times): its window is the map's.
        const line = document.querySelector<HTMLElement>(`[data-tool-id="${TOGGLE_CALL_ID}"][aria-expanded]`);
        if (clicked || !line) return;
        clicked = true;
        clickLine(line);
        // The split's divider moves in the same frame as the click (a pane opening beside the chat).
        if (scenario === "resize-fold") show({ width: 0.8 });
      },
    });
  // fixed-wait: the settle window
  await wait(500);
  sampling = false;
  return samples;
}

(window as unknown as { __compound: { run: typeof run } }).__compound = { run };
