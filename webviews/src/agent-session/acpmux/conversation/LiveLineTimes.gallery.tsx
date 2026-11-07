// l10n-allow-file: gallery fixtures (sample commands), not shipped UI.
// The live line's two times past the turn's first step: a finished step's own time and the turn's
// clock. Leo's capture (2026-11-07) read "python3 - <<'EOF' 3s · 21s · 549 tokens", two bare
// durations with nothing saying which was which. The `live-line-times` arms: both named, "step 3s ·
// turn 21s" (shipped); the turn's clock alone; the step's time alone with the turn's on hover.
// Thinking past the first step keeps its summed thinking bare beside the word, with the turn's
// clock named after it. Test: webviews/test/transcript-live-line-times.test.tsx.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { liveLineTimes } from "./liveLineTimes.experiment";
import { Thinking } from "./Thinking";
import { WorkingCountsContext, type WorkingCounts } from "./WorkingFor";

type Props = { arm: "labelled" | "turn" | "hover"; thinking?: boolean };

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

function Fixture({ arm, thinking = false }: Props) {
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
        {thinking ? (
          <Thinking since={since} below turnTotal verbKey="gallery" thoughtMs={8_000} />
        ) : (
          <Thinking since={since} below turnTotal doing="python3 - <<'EOF'" done doneMs={3_000} />
        )}
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
      note: 'Shipped: "step 3s · turn 21s · 549 tokens", each time named.',
    },
    "turn-only": {
      props: { arm: "turn" },
      note: "The turn's clock alone: \"21s · 549 tokens\"; the step's own time stays on its row.",
    },
    "step-hover": {
      props: { arm: "hover" },
      note: "The step's time alone, \"3s · 549 tokens\"; the turn's clock only in its tooltip.",
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-worked__own" });
      },
    },
    "thinking-labelled": {
      props: { arm: "labelled", thinking: true },
      note: 'Thinking past the first step: "Thinking 8s · turn 21s"; the thinking time stays bare beside its word.',
    },
  },
  load: () => Promise.resolve(Fixture),
});
