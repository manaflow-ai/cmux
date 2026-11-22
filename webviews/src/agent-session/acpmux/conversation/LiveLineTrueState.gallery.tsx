// l10n-allow-file: gallery fixtures, not shipped UI.
// The live line says what is true now (Leo, 2026-11-12, on "Thinking 683ms · turn 15m 15s · 2.2K
// tokens": "this is... i guess maybe ok, but the whatever ms gets stuck and becomes false really
// quickly.... or else gets stale? idk what else you're actually doing so"). Its time beside
// "Thinking" ticks from when this stretch of thinking began, on the page's clock, never a frozen
// sum of the thoughts' spans; a call in flight names itself; and once nothing has arrived for
// SILENT_MS (10 s) the line says "Waiting", calm, with the time since it last heard anything.
// Same single quiet line, tokens only (conversation.css `.cv-worked--live`).
// Tests: webviews/test/transcript-live-line-true-state.test.tsx.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { Thinking } from "./Thinking";
import { WorkingCountsContext, type WorkingCounts } from "./workingForModel";

type Phase = "thinking" | "running" | "waiting" | "subagents";
type Props = { phase: Phase };

const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 2_200,
};

/// Fifteen minutes into the turn, as in Leo's capture.
const TURN_MS = 15 * 60_000 + 15_000;

function Fixture({ phase }: Props) {
  const [now] = useState(() => Date.now());
  const since = now - TURN_MS;
  const line =
    phase === "running"
      ? { doing: "bun test test/fetchJson.test.ts", doingShell: true, doingAt: now - 6_000 }
      : phase === "subagents"
        ? { liveState: "subagents" as const, liveAgents: 2 }
        : phase === "waiting"
          ? // The last chunk came 14 s ago: nothing has arrived since.
            { phaseAt: now - 20_000, heardAt: now - 14_000, heardKey: "gallery" }
          : // Thinking for 4 s, its latest chunk just now.
            { phaseAt: now - 4_000, heardAt: now, heardKey: "gallery" };
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <WorkingCountsContext.Provider value={counts}>
        <Thinking since={since} below turnTotal verbKey="gallery" {...line} />
      </WorkingCountsContext.Provider>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.live-line-true-state",
  title: "Live line: the true state, ticking",
  area: "Agent pane",
  pane: true,
  height: 90,
  widths: { narrow: 360, normal: 560 },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking"],
  variants: {
    thinking: {
      props: { phase: "thinking" },
      note: '"Thinking 4s · turn 15m 15s · 2.2K tokens": this stretch of thinking, ticking each second from its start, with the turn\'s clock after it.',
    },
    running: {
      props: { phase: "running" },
      note: '"Running bun test … 15m 15s · 2.2K tokens": a call in flight names itself the moment it starts.',
    },
    waiting: {
      props: { phase: "waiting" },
      note: '"Waiting 14s · turn 15m 15s · 2.2K tokens": nothing for 10 s, so the line stops saying Thinking; no sweep, the time since it last heard.',
    },
    subagents: {
      props: { phase: "subagents" },
      note: '"Waiting on 2 subagents 15m 15s": the agent waits on its helpers, named, never Thinking.',
    },
  },
  load: () => Promise.resolve(Fixture),
});
