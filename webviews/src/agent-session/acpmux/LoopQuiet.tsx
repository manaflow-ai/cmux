import { useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import type { TaskGoal } from "./goal";
import { useT } from "./i18n";
import { Clock } from "./conversation/icons";
import { useLoopLabel } from "./loopLabel";
import { loopPlace } from "./loopPlace.experiment";
import "./loopQuiet.css";

/// A Claude Code /loop between its runs, in the composer's quiet row after the mode: the clock and
/// "Checking back in 7 min." (or only the time, `short`). It used to stand as its own line over the
/// composer, one more part of the bottom stack (Leo, 2026-11-12: "WE PROb need to start unwinding a
/// lot of these things at the bottom... a lot of stuff is pretty wack around there"); here a loop
/// makes the stack no taller, as the folded `N PRs` count takes no row of its own (design/composer.md
/// rule 10). The agent's wake prompt and reason stay in the tooltip only (cmux#38051). Nothing for
/// any other goal, and nothing in the `stack` arm, where App.tsx draws `LoopStrip` over the composer.
export function LoopQuiet({ goal, now = Date.now }: { goal: TaskGoal | undefined; now?: () => number }) {
  const [arm] = useState(() => experimentArm(loopPlace));
  if (!goal || goal.kind !== "loop" || arm === "stack") return null;
  return <LoopQuietLine goal={goal} short={arm === "short"} now={now} />;
}

function LoopQuietLine({ goal, short, now }: { goal: TaskGoal; short: boolean; now: () => number }) {
  const t = useT();
  const { label, short: time, tooltip } = useLoopLabel(goal, now);
  return (
    <output
      className="acpmux-loop-quiet"
      data-state={goal.status}
      aria-label={`${t("goal.label")}: ${label}`}
      // tooltip-allow: the loop's own wake prompt and reason, which the row never shows inline.
      title={short ? `${label}\n\n${tooltip}` : tooltip}
    >
      <span className="acpmux-loop-quiet-mark" aria-hidden="true">
        <Clock size={14} />
      </span>
      <span className="acpmux-loop-quiet-label" aria-hidden="true">
        {short ? time : label}
      </span>
    </output>
  );
}
