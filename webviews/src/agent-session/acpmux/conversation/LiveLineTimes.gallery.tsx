// l10n-allow-file: gallery fixtures, not shipped UI.
// The live line's times past the turn's first step. Leo's capture (2026-11-07) read "python3 -
// <<'EOF' 3s · 21s · 549 tokens": a held finished step's own time and the turn's clock, two bare
// durations. The line no longer holds a finished step (it reads Thinking the moment a call
// completes), so the two times left are the turn's summed thinking beside "Thinking" and the turn's
// clock. The `live-line-times` arms: the turn's clock named, "Thinking 8s · turn 21s"; the turn's
// clock alone (shipped, as the Codex app's line: Lucas, 2026-11-11); the thinking time alone with the
// turn's on hover. With no thoughts yet the
// line reads "Thinking 21s", the turn's clock beside the word, never named "turn" (Leo, 2026-11-09:
// "when thinking dont add the turn").
// Tests: webviews/test/transcript-live-line-times.test.tsx, transcript-live-line-call-done.test.tsx.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { liveLineTimes } from "./liveLineTimes.experiment";
import { Thinking } from "./Thinking";
import { WorkingCountsContext, type WorkingCounts } from "./workingForModel";

type Props = { arm: "labelled" | "turn" | "hover"; thoughts?: boolean };

const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 549,
};

const scope = globalThis as { cmuxExperiments?: Record<string, string> };

function Fixture({ arm, thoughts = true }: Props) {
  // The arm is the host's override for this stage, set before the line first renders.
  useState(() => {
    scope.cmuxExperiments = { ...scope.cmuxExperiments, [liveLineTimes.id]: arm };
    return arm;
  });
  // 21 seconds into the turn, as in Leo's capture.
  const [since] = useState(() => Date.now() - 21_000);
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <WorkingCountsContext.Provider value={counts}>
        <Thinking since={since} below turnTotal verbKey="gallery" {...(thoughts && { thoughtMs: 8_000 })} />
      </WorkingCountsContext.Provider>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.live-line-times",
  title: "Live line: step time and turn clock",
  area: "Agent pane",
  pane: true,
  height: 90,
  widths: { narrow: 360, normal: 560 },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking"],
  experiment: {
    definition: liveLineTimes,
    script: [{ name: "Point at the step's time", run: (ctx) => ctx.hover({ selector: ".cv-worked__own" }) }],
  },
  variants: {
    labelled: {
      props: { arm: "labelled" },
      note: '"Thinking 8s · turn 21s · 549 tokens", the thinking time beside its word, the turn\'s clock named.',
    },
    "no-thoughts": {
      props: { arm: "labelled", thoughts: false },
      note: 'Right after a call completed, no thoughts yet: "Thinking 21s", never "Thinking · turn 21s".',
    },
    "turn-only": {
      props: { arm: "turn" },
      note: "Shipped: the turn's clock alone, \"Thinking 21s\", as the Codex app's live line has one clock.",
    },
    "step-hover": {
      props: { arm: "hover" },
      note: 'The thinking time alone, "Thinking 8s"; the turn\'s clock only in its tooltip.',
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-worked__own" });
      },
    },
  },
  load: () => Promise.resolve(Fixture),
});
