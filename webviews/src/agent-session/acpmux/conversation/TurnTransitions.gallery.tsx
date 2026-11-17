// l10n-allow-file: deterministic motion fixture labels.
// A running turn's transitions, played in the followed transcript (Leo, 2026-11-07: "the streaming
// text, and then, like, when you stream text, and then you get this burst, and then all of a sudden,
// then you start thinking. It's like, okay, the jumps are jarring. We want to minimize the jumps").
// Each play runs one of the scripted turns test/turn-transition-jumps.test.ts measures
// (scriptedTurn.ts TRANSITION_TURNS). The looks compare how the rows under a change (the live line, a
// steer under its new footer, the turn's footer) move to their new place (`data-tail-glide`,
// tailGlide.ts): `arrive`, shipped, everything on the arrival step (the quick step, 80 ms, longer only
// as a long move's frames need), the follow chase on it too, so the move is over by the time the row
// has faded in; `quick`, on the entry step (120 ms) with the chase on its spring; `glide`, on the
// house settle (180 ms) with the spring; `jump`, at once. The arrival turns (ARRIVAL_TURNS: a thought,
// a tool call, a call joining a group, a subagent; Leo, 2026-11-09: "thinking, tool calls, etc...
// cannot lag nor can they take long") compare `arrive` with the earlier looks;
// test/row-arrival-settle.test.ts measures each one's event to rest (CMUX_ROW_ARRIVAL_LOOKS).
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import {
  CARD_DRAFT,
  playScriptedTurn,
  scriptedHistory,
  type ArrivalTurn,
  type ScriptedView,
  type TransitionTurn,
} from "./scriptedTurn";
import type { TailGlideLook } from "./tailGlide";
import { turnView } from "./turns";

const expanded = new Set<string>();

type GalleryTurn = TransitionTurn | ArrivalTurn;

const LABEL: Record<GalleryTurn, string> = {
  "arrive-thinking": "Thinking, then a call",
  "arrive-tool": "A tool call runs and finishes",
  "arrive-group": "A second call joins a group",
  "arrive-subagent": "A subagent runs and reports",
  "text-tool": "Text, then a tool call",
  "burst-thought": "A burst, then thinking",
  "tool-group": "Calls joining one row",
  "steer-tools": "Steer while a call runs",
  "thought-text": "Thinking, then text",
};

function TurnTransitionsGallery({ turn, look }: { turn: GalleryTurn; look: TailGlideLook }) {
  const [view, setView] = useState<Required<ScriptedView>>(() => ({
    rows: scriptedHistory() as AcpmuxRow[],
    working: false,
    sends: 0,
    card: CARD_DRAFT,
  }));
  const [dock, setDock] = useState<HTMLElement | null>(null);
  const [state, setState] = useState<"ready" | "playing" | "settled">("ready");
  const play = () => {
    if (state === "playing") return;
    setState("playing");
    void playScriptedTurn(turn, {
      show: (next) => setView((now) => ({ ...now, ...next })),
      frame: (draw) => requestAnimationFrame(draw),
    }).then(() => setState("settled"));
  };
  return (
    <div className="acpmux-shell" data-tail-glide={look} style={{ height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="turn-transition-play" onClick={play}>
              {LABEL[turn]}
            </button>
            <output data-testid="turn-transition-state" aria-live="polite">
              {state === "settled" ? "Turn settled" : state === "playing" ? "Playing" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={turnView(view.rows, expanded, { working: view.working })}
            sessionId={`turn-transitions-${turn}-${look}`}
            working={view.working}
            sends={view.sends}
            dock={dock}
            onToggleActivity={() => {}}
            expanded={expanded}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: view.card }} />
          </form>
        </div>
      </div>
    </div>
  );
}

/// Plays the turn and waits until its summary row is drawn and the follow motion rests.
const playTurn: Play = async (ctx) => {
  await ctx.click({ testId: "turn-transition-play" });
  await ctx.waitFor(() => ctx.find({ testId: "turn-transition-state" }).textContent === "Turn settled", {
    capMs: 10_000,
  });
  const thread = ctx.find({ selector: ".acpmux-thread" }) as HTMLElement;
  await ctx.waitFor(() => !thread.style.translate, { capMs: 2_000 });
};

const TURNS: TransitionTurn[] = ["text-tool", "burst-thought", "tool-group", "steer-tools", "thought-text"];
const ARRIVALS: ArrivalTurn[] = ["arrive-thinking", "arrive-tool", "arrive-group", "arrive-subagent"];
const LOOKS: TailGlideLook[] = ["arrive", "quick", "glide", "jump"];
const ARRIVAL_LOOKS: TailGlideLook[] = ["arrive", "quick", "glide"];
const NOTE: Record<TailGlideLook, string> = {
  arrive:
    "Shipped: everything that moves (the rows above, the rows under, the new row's fade) runs on one 80 ms step and rests together.",
  quick: "Before: the rows under the change glide on the entry step (120 ms); the rows above come home on the spring.",
  glide: "The rows under the change glide on the house settle (180 ms); the rows above on the spring.",
  jump: "The rows under the change move at once.",
};

export default componentEntry<{ turn: GalleryTurn; look: TailGlideLook }>({
  id: "agent-pane.turn-transitions",
  title: "Turn transitions",
  area: "Agent pane",
  height: 600,
  anchors: [{ selector: "[data-testid=turn-transition-play]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The transcript's motion must not move the fixed play control." },
    settleMaxMs: { value: 10_000, reason: "A scripted turn streams for up to three seconds, then settles." },
  },
  covers: [
    "agent-session/acpmux/conversation/tailGlide.ts#createTailGlide",
    "agent-session/acpmux/conversation/followChase.ts#createFollowChase",
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
  ],
  load: async () => TurnTransitionsGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants: Object.fromEntries(
    [
      ...TURNS.flatMap((turn) => LOOKS.map((look) => [turn, look] as const)),
      ...ARRIVALS.flatMap((turn) => ARRIVAL_LOOKS.map((look) => [turn, look] as const)),
    ].map(([turn, look]) => [
      `${turn}-${look}`,
      { props: { turn, look }, play: playTurn, note: `${LABEL[turn]}. ${NOTE[look]}` },
    ]),
  ),
});
