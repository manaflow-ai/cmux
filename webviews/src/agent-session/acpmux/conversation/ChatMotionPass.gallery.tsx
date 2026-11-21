// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The chat's one motion pass (Leo, 2026-11-09): "these animations all slosh around and it's not
// cohesive / i previously sent the claude code one, just look at how they do it"; "i hate the way
// when i send off a message it seems to move up and under your current running tool call or
// whatever"; "im still seeing compacting not be at the bottom"; "at really high loads if it knows it
// can't performantly perform the animation... it just goes into minimal ish mode?"; "and your
// thinking disappeared?".
// - mid-turn send: the reader sends while a call runs (scriptedTurn.ts `steer-tools`). The call stays
//   on the live line under the prompt and lands after it when it ends; nothing above the prompt moves
//   (turns.ts `afterSends`). Product arm (`send`): only the send rises on a curve, the rest lands in
//   its frame. `before`: the spring chase arm the pass replaced, for comparison.
// - minimal: the same turn with the chat in its minimal motion (frameBudget.ts): nothing animates.
// - compacting last: a compaction running when the person sent stays the live line, under the prompt.
// - inbox during a live thought: another session's message waits (the group of waiting messages)
//   while the agent thinks: the thought stays in its run and the live line stays the last row.
// Tests: webviews/test/transcript-live-zone-last.test.ts, turn-transition-jumps.test.ts (steer-tools),
// conversation/frameBudget.test.ts.
import { useEffect, useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { VirtualTranscript } from "../App";
import type { AcpmuxRow } from "../model";
import { CHAT_MOTION_ATTR, MINIMAL_MOTION } from "./frameBudget";
import { followMotion } from "./followMotion.experiment";
import { pendingMessagesRow, withWaitingRows } from "./pendingMessages";
import { CARD_DRAFT, playScriptedTurn, scriptedHistory, type ScriptedView } from "./scriptedTurn";
import { turnView } from "./turns";

const expanded = new Set<string>();
const scope = globalThis as { cmuxExperiments?: Record<string, string> };

type Still = "compacting-last" | "inbox-thought";
type Props = { arm?: "send" | "blocks"; minimal?: boolean; still?: Still };

const START = Date.UTC(2026, 10, 9, 19, 0, 0);
const at = (second: number) => START + second * 1000;
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: at(second),
  ...extra,
});

/// A still state's rows, as App.tsx draws them (turn shaping, then the group of waiting messages).
function stillRows(still: Still): AcpmuxRow[] {
  const base = [
    ...(scriptedHistory() as AcpmuxRow[]),
    row("u-live", "user", 0, { text: "Finish the migration and run the tests" }),
    row("a-live", "assistant", 4, { text: "The migration is applied; running the tests next." }),
  ];
  if (still === "compacting-last")
    return turnView(
      [
        ...base,
        row("compaction-live", "compaction", 6, { compaction: { state: "running" } }),
        row("u-steer", "user", 9, { text: "Also check the queue that replays requests.", steer: "waiting" }),
      ],
      expanded,
      { working: true, now: at(30) },
    );
  const thinking = row("act-live", "activity", 6, {
    streaming: true,
    items: [
      {
        kind: "thought",
        text: "The retry cap lives in the relay client; the upload queue reuses it, so one change covers both.",
        startedAt: at(6),
        endedAt: at(9),
      },
    ],
  });
  const shaped = turnView([...base, thinking], expanded, { working: true, now: at(12) });
  const text = "goal-cloud-environment-auto-3 · gcp-codex-lane-10: the environment check passed";
  const waiting: AcpmuxRow = {
    id: "inbox-1",
    version: 1,
    at: at(10),
    kind: "queuedMessage",
    text,
    incoming: { kind: "message", message: { name: "gcp-codex-lane-10", text, raw: text } },
    queuedMessage: { promptId: "inbox-1" },
  };
  const group = pendingMessagesRow([], [waiting]);
  return group ? withWaitingRows(shaped, [group]) : shaped;
}

function ChatMotionPassGallery({ arm, minimal = false, still }: Props) {
  // The arm is read once by the transcript as it mounts: set it for this one, then put it back.
  const [saved] = useState(() => {
    const before = scope.cmuxExperiments;
    if (arm) scope.cmuxExperiments = { ...before, [followMotion.id]: arm };
    return before;
  });
  useEffect(() => {
    if (arm) scope.cmuxExperiments = saved;
  }, [arm, saved]);
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
    void playScriptedTurn("steer-tools", {
      show: (next) => setView((now) => ({ ...now, ...next })),
      frame: (draw) => requestAnimationFrame(draw),
    }).then(() => setState("settled"));
  };
  const rows = still ? stillRows(still) : turnView(view.rows, expanded, { working: view.working });
  return (
    <div className="acpmux-shell" style={{ height: "100%" }} {...(minimal && { [CHAT_MOTION_ATTR]: MINIMAL_MOTION })}>
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header">
            {!still && (
              <button type="button" className="ui-button" data-testid="chat-motion-play" onClick={play}>
                Send while a call runs
              </button>
            )}
            <output data-testid="chat-motion-state" aria-live="polite">
              {state === "settled" ? "Turn settled" : state === "playing" ? "Playing" : "Ready"}
            </output>
          </header>
          <VirtualTranscript
            rows={rows}
            sessionId={`chat-motion-pass-${still ?? arm ?? "send"}${minimal ? "-minimal" : ""}`}
            working={still ? true : view.working}
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

/// Plays the mid-turn send and waits until the turn settles.
const playTurn: Play = async (ctx) => {
  await ctx.click({ testId: "chat-motion-play" });
  await ctx.waitFor(() => ctx.find({ testId: "chat-motion-state" }).textContent === "Turn settled", {
    capMs: 10_000,
  });
};

export default componentEntry<Props>({
  id: "agent-pane.chat-motion-pass",
  title: "Chat motion: mid-turn send, live zone last, minimal motion",
  area: "Agent pane",
  height: 600,
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/turns.ts#afterSends",
    "agent-session/acpmux/conversation/frameBudget.ts#createFrameBudget",
  ],
  load: async () => ChatMotionPassGallery,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../composerStates.css"),
      import("../bottomStack.css"),
    ]),
  variants: {
    "mid-turn-send": {
      props: { arm: "send" },
      play: playTurn,
      note: "Sent while Read relay.ts runs: the call stays on the live line under the prompt and lands after it; nothing above moves.",
    },
    "mid-turn-send-before": {
      props: { arm: "blocks" },
      play: playTurn,
      note: "Before: the spring chase arm, every row's move glides home on its own curve.",
    },
    "minimal-motion": {
      props: { arm: "send", minimal: true },
      play: playTurn,
      note: "The chat missed its frame budget: every row lands in its frame, nothing glides or fades.",
    },
    "compacting-last": {
      props: { still: "compacting-last" },
      note: "A compaction running when the person sent stays the live line, under the prompt.",
    },
    "inbox-during-thought": {
      props: { still: "inbox-thought" },
      note: "Another session's message waits while the agent thinks: the thought stays in its run, the live line last.",
    },
  },
});
