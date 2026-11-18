// l10n-allow-file: deterministic motion fixture labels.
// Sending and a fast reply in the followed transcript, per arm of the follow motion
// (followMotion.experiment.ts; Leo, 2026-11-07: "When it comes to sending messages, I feel like the
// jump, the jolt is a bit too jarring ... what is satisfying at 120 hertz?"). Each play runs one of
// the scripted turns test/send-stream-motion.test.ts measures (scriptedTurn.ts): a send and a fast
// stream, a turn with a thought and tool calls, and a steer while the reply streams.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { followMotion } from "./followMotion.experiment";
import { CARD_DRAFT, playScriptedTurn, scriptedHistory, type ScriptedTurn, type ScriptedView } from "./scriptedTurn";
import { turnView } from "./turns";

const expanded = new Set<string>();

function SendStreamMotionGallery({ turn }: { turn: ScriptedTurn }) {
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
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            <button type="button" className="ui-button" data-testid="send-stream-play" onClick={play}>
              {turn === "send" ? "Send and stream" : turn === "tools" ? "Stream with tools" : "Steer mid-stream"}
            </button>
            <output data-testid="send-stream-state" aria-live="polite">
              {state === "settled" ? "Turn settled" : state === "playing" ? "Playing" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={turnView(view.rows, expanded, { working: view.working })}
            sessionId={`send-stream-motion-${turn}`}
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
  ctx.motion.start({ kind: "streaming-follow", target: ".acpmux-scroll", maxMs: 8_000 });
  await ctx.click({ testId: "send-stream-play" });
  await ctx.waitFor(() => ctx.find({ testId: "send-stream-state" }).textContent === "Turn settled", { capMs: 10_000 });
  const thread = ctx.find({ selector: ".acpmux-thread" }) as HTMLElement;
  await ctx.waitFor(() => !thread.style.translate, { capMs: 2_000 });
  const report = ctx.motion.stop();
  if (!report || report.status === "fail") throw new Error(report?.problems.join("; ") ?? "the turn was not sampled");
};

export default componentEntry<{ turn: ScriptedTurn }>({
  id: "agent-pane.send-stream-motion",
  title: "Send and stream motion",
  area: "Agent pane",
  height: 600,
  anchors: [{ selector: "[data-testid=send-stream-play]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The transcript's motion must not move the fixed play control." },
    settleMaxMs: { value: 10_000, reason: "A scripted turn streams for up to four seconds, then settles." },
  },
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/followChase.ts#createFollowChase",
  ],
  load: async () => SendStreamMotionGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants: {
    "send-stream": {
      props: { turn: "send" },
      play: playTurn,
      note: "Send from the latest message, then a fast reply.",
    },
    "tools-turn": { props: { turn: "tools" }, play: playTurn, note: "A reply, a thought, two tool calls, more reply." },
    "steer-mid-stream": { props: { turn: "steer" }, play: playTurn, note: "A steer sent while the reply streams." },
  },
  experiment: {
    definition: followMotion,
    script: [{ name: "Send and stream", run: playTurn }],
  },
});
