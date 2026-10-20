// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. After the time it counts the work still going in
// the background, as Claude's phone app does ("Working… · 5 running tasks"): "· 2 agents ·
// 1 command", only subagents still running and background shells that have not ended. Each count
// opens what it counts. The counts follow the label on the same fixed-height line, so one that
// comes or goes moves neither the label nor the rows below. When the turn ends, the "Worked for"
// disclosure takes its place.
import { createContext, useContext, useEffect, useState } from "react";
import { type Translate, useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";

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

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const counts = useContext(WorkingCountsContext);
  const [time, setTime] = useState(now);
  const held = row.durationMs !== undefined;
  useEffect(() => {
    if (held) return;
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now, held]);
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
    <div className="cv-worked has-divider">
      <span className="cv-worked__label">{workingLabel(t, row.at, held ? row.at + row.durationMs! : time)}</span>
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
