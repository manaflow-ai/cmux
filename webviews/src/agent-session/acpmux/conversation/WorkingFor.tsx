// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. While a call runs (`row.doing`, turns.ts) it names
// that call beside the time instead, as Claude desktop's line does, after the same small animated
// mark as "Thinking". After that it counts the work still going in the background, as Claude's
// phone app does ("Working… · 5 running tasks"): "· 2 agents · 1 command", only subagents still
// running and background shells that have not ended. Each count opens what it counts. The counts
// follow on the same fixed-height line, so one that comes or goes moves neither the label nor the
// rows below. When the turn ends, the "Worked for" disclosure takes its place.
//
// Drawn as the turn's last row (`row.below`, Debug Settings `agentPane.debug.liveLineBelow`), it
// has no rule under it and its clock never stops while the turn runs, and before any output
// (`row.thinkingNow`) it reads "Thinking" beside the time.
import { createContext, useContext, useEffect, useState } from "react";
import { type Translate, useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";
import { WorkingMark } from "./WorkingMark";

export const workingLabel = (t: Translate, at: number, now: number) =>
  t("turn.working", { time: formatDuration(Math.max(0, now - at)) });

/// What the running turn's line counts (App.tsx): the subagents and background shells still
/// running, and what opens each.
export type WorkingCounts = {
  agents: number;
  commands: number;
  openAgents: () => void;
  openCommands: () => void;
};

export const WorkingCountsContext = createContext<WorkingCounts | undefined>(undefined);

/// `now()`, again each second while `running`.
export function useTicking(running: boolean, now: () => number = Date.now): number {
  const [time, setTime] = useState(now);
  useEffect(() => {
    if (!running) return;
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now, running]);
  return time;
}

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const counts = useContext(WorkingCountsContext);
  const held = !row.below && row.durationMs !== undefined;
  const time = useTicking(!held, now);
  const until = held ? row.at + row.durationMs! : time;
  const parts = counts
    ? [
        counts.agents > 0 && {
          key: "agents",
          label: t("turn.working.agents", { n: counts.agents }),
          open: counts.openAgents,
        },
        counts.commands > 0 && {
          key: "commands",
          label: t("turn.working.commands", { n: counts.commands }),
          open: counts.openCommands,
        },
      ].filter((part) => part !== false)
    : [];
  return (
    // Find counts and visits transcript rows only (chatFind.ts findMatches skips this row), so the
    // line is not painted either: the call it names is matched on its own tool row.
    <div className={row.below ? "cv-worked is-below" : "cv-worked has-divider"} data-find-skip>
      <WorkingMark />
      {row.doing || row.thinkingNow ? (
        <>
          <span className={row.doing ? "cv-worked__label cv-worked__doing" : "cv-worked__label"}>
            {row.doing ?? t("thinking")}
          </span>
          <span className="cv-worked__time">{formatDuration(Math.max(0, until - row.at))}</span>
        </>
      ) : (
        <span className="cv-worked__label">{workingLabel(t, row.at, until)}</span>
      )}
      {parts.map((part) => (
        <span key={part.key} className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <button type="button" className="cv-worked__open" onClick={part.open}>
            {part.label}
          </button>
        </span>
      ))}
    </div>
  );
}
