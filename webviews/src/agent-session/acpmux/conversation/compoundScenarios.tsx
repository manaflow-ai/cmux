// l10n-allow-file: gallery and test fixtures (sample prompts and replies), not shipped UI.
// The compound motions of the agent pane, one scripted case each, for the motion map
// (webviews/test/compound-motion.test.ts) and the gallery (CompoundMotion.gallery.tsx). Leo,
// 2026-11-22: "there are a lot of these possible compound movement situations, esp with folds, that i
// think we can watch for and map out harder to have more cohesive animations."
//
// The pane is the real VirtualTranscript over a chat's history, followed at its latest row, with a
// stand-in for the docked composer: a card whose prompt field grows on the composer's own growth
// event (composer/fieldGrowth.ts), and a queue card the stack can bring. Every case plays on timers,
// as a socket's events land, and names the step its event starts in (EVENT_STEP).
import { useState } from "react";
import { VirtualTranscript } from "../App";
import { FIELD_GROWTH_EVENT, type FieldGrowthDetail } from "../composer/fieldGrowthEvent";
import type { AcpmuxRow } from "../model";
import { MOTION_MS, MOTION_SETTLE } from "../../../motion/scale.generated";
import { REPLY } from "./streamingTextFixture";
import {
  CARD_DRAFT,
  CARD_EMPTY,
  playScriptedTurn,
  scriptedHistory,
  SCRIPTED_PROMPT_ID,
  TOGGLE_CALL_ID,
  type ScriptedTurn,
} from "./scriptedTurn";
import { turnView } from "./turns";
import type { CompoundCase } from "./compoundCases";

export { COMPOUND_CASES, EVENT_STEP, type CompoundCase } from "./compoundCases";

/// The cases that are a scripted turn (scriptedTurn.ts), and which one.
const SCRIPTED: Partial<Record<CompoundCase, ScriptedTurn>> = {
  steer: "steer-tools",
  "fold-stream": "tool-toggle",
  "resize-fold": "tool-toggle",
  "subagent-land": "arrive-subagent",
  "recap-end": "tools",
};

/// One composer line (the field's line box, as scriptedTurn.ts CARD_DRAFT counts it), px.
const LINE = (CARD_DRAFT - CARD_EMPTY) / 2;
/// The empty card's field: one line; the rest of the card is its chrome.
const FIELD_EMPTY = LINE;

export type PaneState = {
  rows: AcpmuxRow[];
  working: boolean;
  sends: number;
  card: number;
  /// A queue card over the composer, px tall (0: none).
  queue: number;
  /// The pane's width share (1: all of it), for the split resize.
  width: number;
};

const expanded = new Set<string>();

/// The pane the cases play in; `bind` hands out its state setter.
export function CompoundPane({
  bind,
  sessionId,
}: {
  bind: (show: (next: Partial<PaneState>) => void) => void;
  sessionId: string;
}) {
  const [now, setState] = useState<PaneState>(() => ({
    rows: scriptedHistory(),
    working: false,
    sends: 0,
    card: CARD_EMPTY,
    queue: 0,
    width: 1,
  }));
  const [dock, setDock] = useState<HTMLElement | null>(null);
  bind((next) => setState((was) => ({ ...was, ...next })));
  return (
    <div className="acpmux-shell" style={{ width: `${now.width * 100}%`, height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(now.rows, expanded, { working: now.working })}
            sessionId={sessionId}
            working={now.working}
            sends={now.sends}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          {now.queue > 0 && <div data-compound-queue style={{ height: now.queue }} />}
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div
              className="acpmux-composer-box"
              data-page-glass="docked composer specimen: the page's glass, as ComposerBox.tsx"
            >
              <div className="acpmux-md-field" style={{ height: now.card - CARD_EMPTY + FIELD_EMPTY }} />
              <div style={{ height: CARD_EMPTY - FIELD_EMPTY }} />
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/// A pointer's click on `target` at its middle, as a mouse delivers it.
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

/// The prompt field grows by `lines` on its own motion and tells the transcript, as
/// composer/fieldGrowth.ts does when its motion starts.
function growField(root: ParentNode, lines: number) {
  const field = root.querySelector<HTMLElement>(".acpmux-md-field");
  if (!field) return;
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

export type CompoundOptions = {
  show: (next: Partial<PaneState>) => void;
  /// Runs `draw` in the next display frame.
  frame: (draw: () => void) => void;
  /// Names the step the case is in.
  step: (name: string) => void;
  /// The pane's root (the field and the call's line are found under it).
  root: ParentNode;
};

/// A send of `lines` lines from the latest row: the draft's card clears to one line as `sends` counts
/// one, and acpmux's echo brings the prompt's row and the live line 30 ms later (scriptedTurn `send`).
/// A send: the card collapses, and the prompt's row lands 30 ms later, or in the send's own commit
/// (`oneCommit`, what a loaded host draws: the prompt is there before the send's effect runs).
async function send(lines: number, { show, step }: CompoundOptions, oneCommit = false) {
  show({ card: CARD_EMPTY + (lines - 1) * LINE });
  await wait(300);
  const text = Array.from({ length: lines }, (_, index) => `Line ${index + 1} of the prompt.`).join("\n");
  const prompt = {
    rows: [...scriptedHistory(), { id: SCRIPTED_PROMPT_ID, version: 1, at: Date.now(), kind: "user" as const, text }],
    working: true,
  };
  step("send");
  if (oneCommit) show({ sends: 1, card: CARD_EMPTY, ...prompt });
  else {
    show({ sends: 1, card: CARD_EMPTY });
    await wait(30);
    show(prompt);
  }
  await wait(700);
}

/// A send while a turn runs, scrolled up (lane-3's case, cmux#49888): the draft's card clears as the
/// transcript goes to its latest row for the send, and acpmux takes the prompt into the queue (a card
/// over the composer) 40 ms later; the reply keeps streaming under it.
async function queueScrolled({ show, frame, step, root }: CompoundOptions) {
  const base = scriptedHistory();
  const prompt: AcpmuxRow = {
    id: SCRIPTED_PROMPT_ID,
    version: 1,
    at: Date.now(),
    kind: "user",
    text: "Why does the relay fall over?",
  };
  const text = REPLY.split("\n\n").slice(0, 3).join("\n\n");
  const reply = (length: number, version: number): AcpmuxRow => ({
    id: "live-answer",
    version,
    at: Date.now(),
    kind: "assistant",
    text: text.slice(0, length),
    streaming: true,
  });
  show({ rows: [...base, prompt, reply(text.length / 2, 1)], working: true, card: CARD_EMPTY + 4 * LINE });
  await wait(300);
  const scroller = root.querySelector<HTMLElement>(".acpmux-scroll");
  if (scroller) scroller.scrollTop = Math.max(0, scroller.scrollTop - 260);
  await wait(300);
  step("send");
  show({ sends: 1, card: CARD_EMPTY });
  await wait(40);
  show({ queue: LINE * 2 });
  for (let version = 2; version < 30; version += 1) {
    frame(() => show({ rows: [...base, prompt, reply(text.length / 2 + version * 8, version)] }));
    await wait(16);
  }
  await wait(300);
}

/// A reply streams (24 characters every 16 ms) and `event` lands 25 deltas in.
async function streamWith(name: string, event: () => void, { show, frame, step }: CompoundOptions) {
  const base = scriptedHistory();
  const prompt: AcpmuxRow = {
    id: SCRIPTED_PROMPT_ID,
    version: 1,
    at: Date.now(),
    kind: "user",
    text: "Why does the relay fall over?",
  };
  show({ rows: [...base, prompt], working: true });
  await wait(300);
  step("stream");
  const text = REPLY.split("\n\n").slice(0, 8).join("\n\n");
  for (let index = 0, version = 1; index < text.length; index += 24, version += 1) {
    if (index === 24 * 25) {
      step(name);
      event();
    }
    const reply: AcpmuxRow = {
      id: "live-answer",
      version,
      at: Date.now(),
      kind: "assistant",
      text: text.slice(0, index + 24),
      streaming: true,
    };
    frame(() => show({ rows: [...base, prompt, reply] }));
    await wait(16);
  }
  await wait(500);
}

/// Plays one case; resolves once it settled.
export async function playCompound(which: CompoundCase, options: CompoundOptions): Promise<void> {
  const { show, frame, step, root } = options;
  const scripted = SCRIPTED[which];
  let clicked = false;
  if (which === "control") {
    step("rest");
    await wait(600);
  } else if (which === "send-1" || which === "send-5" || which === "send-15")
    await send(Number(which.slice("send-".length)), options);
  else if (which === "send-5-one-commit") await send(5, options, true);
  else if (which === "queue-scrolled") await queueScrolled(options);
  else if (which === "growth-stream") await streamWith("grow", () => growField(root, 2), options);
  else if (which === "stack-stream") await streamWith("queue", () => show({ queue: LINE * 3 }), options);
  else if (scripted)
    await playScriptedTurn(scripted, {
      show,
      frame,
      step,
      act: () => {
        // Only the first click (the toggle turn clicks five times): its window is the map's.
        const line = root.querySelector<HTMLElement>(`[data-tool-id="${TOGGLE_CALL_ID}"][aria-expanded]`);
        if (clicked || !line) return;
        clicked = true;
        clickLine(line);
        // The split's divider moves in the same frame as the click (a pane opening beside the chat).
        if (which === "resize-fold") show({ width: 0.8 });
      },
    });
  await wait(500);
}
