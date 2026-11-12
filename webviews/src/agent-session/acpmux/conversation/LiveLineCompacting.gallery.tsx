// l10n-allow-file: gallery fixtures (sample replies), not shipped UI.
// The live line while the agent compacts the conversation (Leo, 2026-11-07: "when you're compacting
// the conversation, just show it as you're compacting ... You're not thinking during this time. So
// it shouldn't be labeled as thinking ... That should replace the thinking area"). Before, a
// "Compacting the conversation…" row sat over "Thinking 1m 35s · 1.8K tokens"; now the line itself
// says "Compacting conversation…" with the compaction's own clock and no token count, and the row
// folds into it (conversation/turns.ts `codexLiveTurn`). Entering and leaving roll the words in
// place (Thinking.tsx `useRoll`); the line keeps its box, so nothing below or beside it moves. When
// the compaction ends its note ("Conversation compacted · 412k → 18k") lands in the transcript and
// the line rolls back to Thinking at once, as after any finished step. The
// mid-change variants hold the roll at one moment; Replay plays it. The `compacting-line` arms
// differ in the clock: the compaction's own (shipped), its own then the turn's, or none.
// Test: webviews/test/transcript-live-line-compacting.test.tsx.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxCompaction } from "../model";
import { CompactionNote } from "./CompactionNote";
import { compactingLine } from "./compactingLine.experiment";
import { Thinking } from "./Thinking";
import { WorkingCountsContext, type WorkingCounts } from "./workingForModel";

type Phase = "before" | "thinking" | "compacting" | "compacted";
type Props = { phase: Phase; arm?: "own" | "turn" | "calm"; accountSwitch?: boolean };

const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 1_800,
};

const scope = globalThis as { cmuxExperiments?: Record<string, string> };

function Fixture({ phase: start, arm, accountSwitch = false }: Props) {
  // The arm is the host's override for this stage, set before the line first renders.
  useState(() => {
    if (arm) scope.cmuxExperiments = { ...scope.cmuxExperiments, [compactingLine.id]: arm };
    return arm;
  });
  const [phase, setPhase] = useState(start);
  // A minute and a half into the turn, as in Leo's capture; the compaction started 12 seconds ago.
  const [since] = useState(() => Date.now() - 95_000);
  const [compactedAt, setCompactedAt] = useState(() => Date.now() - 12_000);
  const reason = accountSwitch ? { reason: "account_switch" } : {};
  const running: AcpmuxCompaction = { state: "running", ...reason };
  const completed: AcpmuxCompaction = { state: "completed", preTokens: 412_000, postTokens: 18_400, ...reason };
  // Base drew the running note as its own row; a finished compaction is a row again.
  const note = phase === "before" ? running : phase === "compacted" ? completed : undefined;
  const held = phase === "compacting" ? running : undefined;
  const step = (next: Phase) => () => {
    if (next === "compacting") setCompactedAt(Date.now());
    setPhase(next);
  };
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        <button type="button" onClick={step("compacting")}>
          Start compacting
        </button>
        <button type="button" onClick={step("compacted")}>
          Finish compacting
        </button>
      </div>
      <p style={{ margin: "0 0 8px", color: "var(--cv-text)" }}>The migration is applied; running the tests next.</p>
      {note && <CompactionNote compaction={note} />}
      <WorkingCountsContext.Provider value={counts}>
        <Thinking
          since={since}
          below
          turnTotal
          verbKey="gallery"
          {...(held && { liveState: "compacting" as const, liveCompaction: held, doingAt: compactedAt })}
        />
      </WorkingCountsContext.Provider>
    </div>
  );
}

/// The roll's own animations (the shimmer's endless loops keep running).
const rollAnimations = (doc: Document) =>
  doc
    .getAnimations()
    .filter((animation) => animation.effect?.getTiming().iterations !== Infinity && animation.playState !== "finished");

/// Hold the roll `ms` in, so the still shows the old words leaving and the new arriving.
const holdAt = (ms: number) => (ctx: PlayContext) => {
  for (const animation of rollAnimations(ctx.document)) {
    animation.pause();
    animation.currentTime = ms;
  }
};
const start = (ctx: PlayContext) => ctx.click({ role: "button", name: "Start compacting" });
const finish = (ctx: PlayContext) => ctx.click({ role: "button", name: "Finish compacting" });
const settled = (ctx: PlayContext) => ctx.waitFor(() => rollAnimations(ctx.document).length === 0);

export default componentEntry<Props>({
  id: "agent-pane.live-line-compacting",
  title: "Live line while the conversation compacts",
  area: "Agent pane",
  pane: true,
  height: 170,
  widths: { narrow: 360, normal: 560 },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  covers: [
    "agent-session/acpmux/conversation/Thinking.tsx#Thinking",
    "agent-session/acpmux/conversation/CompactionNote.tsx#CompactionNote",
  ],
  experiment: {
    definition: compactingLine,
    script: [
      { name: "Start compacting", run: start },
      { name: "Finish compacting", run: finish },
    ],
  },
  variants: {
    before: {
      props: { phase: "before" },
      note: 'Base, as Leo captured it: a "Compacting the conversation…" row over "Thinking 1m 35s · 1.8K tokens".',
    },
    rest: {
      props: { phase: "compacting" },
      note: 'Compacting: one line, "Compacting conversation…" with the compaction\'s own clock, no Thinking and no tokens.',
    },
    entering: {
      props: { phase: "thinking" },
      note: "60 ms into a compaction's start: Thinking rolls out above as Compacting rolls in, in the same box.",
      play: async (ctx) => {
        await start(ctx);
        holdAt(60)(ctx);
      },
    },
    leaving: {
      props: { phase: "compacting" },
      note: "60 ms into its end: Compacting rolls out above as Thinking rolls in; the note lands in the transcript.",
      play: async (ctx) => {
        await finish(ctx);
        holdAt(60)(ctx);
      },
    },
    left: {
      props: { phase: "compacting" },
      note: 'Ended: "Conversation compacted · context 412k → 18k" in the transcript, the line on Thinking with the turn\'s clock and tokens.',
      play: async (ctx) => {
        await finish(ctx);
        await settled(ctx);
      },
    },
    "account-switch": {
      props: { phase: "compacting", accountSwitch: true },
      note: "subrouter compacting to move the chat to another account: the line keeps that string's meaning.",
    },
    "arm-turn": {
      props: { phase: "compacting", arm: "turn" },
      note: "Arm `turn`: the compaction's time, then the turn's after a dot.",
    },
    "arm-calm": {
      props: { phase: "compacting", arm: "calm" },
      note: "Arm `calm`: no clock and no shimmer, as the retry line reads.",
    },
  },
  load: () => Promise.resolve(Fixture),
});
