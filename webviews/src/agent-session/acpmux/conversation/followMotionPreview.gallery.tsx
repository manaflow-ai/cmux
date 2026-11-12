// l10n-allow-file: gallery fixtures and arm labels (developer tool), not shipped UI.
// The follow motion's arms side by side (followMotion.experiment.ts), so they can be felt against
// each other in one view. Leo, 2026-11-12, relayed: he had not seen previews of the transcript's
// follow animation. Each cell is a real VirtualTranscript forced to one arm (FollowArmOverride), and
// one script drives every cell from the same state in the same frames (scriptedTurn.ts
// `send-tools-send`): a send from the latest row, a fast reply, a tool call, more reply, and a
// second send while the reply streams. Replay starts every cell again from the history. The arm the
// app ships is unchanged (the experiment's `defaultArm`); this page only forces arms per cell.
import { useState } from "react";
import { armIds } from "../../../experiments/experiment";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { FollowArmOverride } from "./followArmOverride";
import { followMotion, type FollowMotionArm } from "./followMotion.experiment";
import { CARD_DRAFT, playScriptedTurn, scriptedHistory, type ScriptedView } from "./scriptedTurn";
import { turnView } from "./turns";

const expanded = new Set<string>();

const startView = (): Required<ScriptedView> => ({
  rows: scriptedHistory() as AcpmuxRow[],
  working: false,
  sends: 0,
  card: CARD_DRAFT,
});

function ArmCell({ arm, run, view }: { arm: FollowMotionArm; run: number; view: Required<ScriptedView> }) {
  const [dock, setDock] = useState<HTMLElement | null>(null);
  const { label, description } = followMotion.arms[arm];
  return (
    <figure className="follow-motion-preview__cell" data-arm={arm}>
      <figcaption className="follow-motion-preview__caption">
        <span className="follow-motion-preview__label">
          {label}
          {arm === followMotion.defaultArm ? " (ships today)" : ""}
        </span>
        <span className="follow-motion-preview__note" title={description}>
          {description}
        </span>
      </figcaption>
      <FollowArmOverride.Provider value={arm}>
        <div className="acpmux-shell">
          <div className="acpmux-main" data-dock="float">
            <div className="acpmux-stage">
              <VirtualTranscript
                // A new run mounts a new transcript, so every arm starts from the bottom at rest.
                key={run}
                rows={turnView(view.rows, expanded, { working: view.working })}
                sessionId={`follow-motion-preview-${arm}-${run}`}
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
      </FollowArmOverride.Provider>
    </figure>
  );
}

type PreviewProps = { arms: FollowMotionArm[]; columns: number };

function FollowMotionPreview({ arms, columns }: PreviewProps) {
  const [view, setView] = useState(startView);
  const [run, setRun] = useState(0);
  const [state, setState] = useState<"ready" | "playing" | "settled">("ready");
  const replay = () => {
    if (state === "playing") return;
    setView(startView());
    setRun((now) => now + 1);
    setState("playing");
    // Wait a frame so the new transcripts mount at rest on the history before the send.
    requestAnimationFrame(() => {
      void playScriptedTurn("send-tools-send", {
        show: (next) => setView((now) => ({ ...now, ...next })),
        frame: (draw) => requestAnimationFrame(draw),
      }).then(() => setState("settled"));
    });
  };
  return (
    <div className="follow-motion-preview">
      <div className="follow-motion-preview__bar">
        <button
          type="button"
          className="ui-button"
          data-testid="follow-motion-replay"
          onClick={replay}
          disabled={state === "playing"}
        >
          {state === "ready" ? "Play" : "Replay"}
        </button>
        <output className="follow-motion-preview__state" data-testid="follow-motion-state" aria-live="polite">
          {state === "settled" ? "Turn settled" : state === "playing" ? "Playing" : "Ready"}
        </output>
      </div>
      <div
        className="follow-motion-preview__grid"
        style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
      >
        {arms.map((arm) => (
          <ArmCell key={arm} arm={arm} run={run} view={view} />
        ))}
      </div>
    </div>
  );
}

/// Plays the turn in every cell and waits until it settles and every cell's chase rests.
const playAll: Play = async (ctx) => {
  await ctx.click({ testId: "follow-motion-replay" });
  await ctx.waitFor(() => ctx.find({ testId: "follow-motion-state" }).textContent === "Turn settled", {
    capMs: 12_000,
  });
  const threads = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-thread")];
  await ctx.waitFor(() => threads.every((thread) => !thread.style.translate), { capMs: 2_000 });
};

export default componentEntry<PreviewProps>({
  id: "agent-pane.follow-motion-preview",
  title: "Follow motion, every arm side by side",
  area: "Agent pane",
  height: 820,
  anchors: [{ selector: "[data-testid=follow-motion-replay]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The transcripts' motion must not move the fixed Replay control." },
    settleMaxMs: { value: 12_000, reason: "The scripted turn streams for about four seconds, then settles." },
  },
  covers: [
    "agent-session/acpmux/conversation/followArmOverride.ts#FollowArmOverride",
    "agent-session/acpmux/conversation/followChase.ts#createFollowChase",
  ],
  load: async () => FollowMotionPreview,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
      import("./followMotionPreview.gallery.css"),
    ]),
  variants: {
    "all-arms": {
      props: { arms: armIds(followMotion), columns: 3 },
      play: playAll,
      note: "Every arm, one script: send, fast reply, a tool call, a second send mid-stream. Replay runs it again.",
    },
    "shipped-vs-instant": {
      props: { arms: [...new Set<FollowMotionArm>([followMotion.defaultArm, "spring", "instant"])], columns: 3 },
      play: playAll,
      note: "The arm that ships, the plain spring chase, and no motion at all (At once).",
    },
  },
});
