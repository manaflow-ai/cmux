import { createContext } from "react";
import { usePageNow } from "../../../ui/pageClock";
import { agentStartStage } from "../cloudStartViewModel";
import { useT } from "../i18n";
import { ShimmerText } from "./ShimmerText";
import { formatDuration } from "./turns";
import "../cloudStart.css";

/// The agent a Cloud chat starts on its machine (App.tsx sets it on a Cloud chat only): while its
/// first prompt waits for that agent, the transcript's live line names it (CloudAgentStartLine).
export const CloudAgentStartContext = createContext<string | undefined>(undefined);

/// A Cloud chat's queued first prompt on the machine's chat page, while its agent starts: the line the
/// Mac's start view ended on ("Starting Claude Code" and its clock, CloudStartView
/// StageLine), with its clock, in place of a bare "Thinking". One line in the live line's own box, so
/// the answer's first words take its place with no shift and no Cancel (Leo, 2026-11-01). Past
/// AGENT_START_SLOW_MS the usual wait reads "taking longer than usual".
export function CloudAgentStartLine({ agent, since, below }: { agent: string; since?: number; below?: boolean }) {
  const t = useT();
  const now = usePageNow(true);
  const stage = agentStartStage(agent, since, now, t);
  const clock = since === undefined ? undefined : formatDuration(Math.max(0, now - since));
  return (
    <div
      className={"cv-worked cv-worked--live acpmux-cloud-start__agent" + (below ? " is-below" : "")}
      data-find-skip
      data-cloud-agent-start
    >
      <span className="cv-shimmer__row">
        <output className="cv-thinking is-shimmer">
          <ShimmerText text={stage.label} />
        </output>
        {clock && <span className="cv-worked__time">{clock}</span>}
      </span>
      {stage.detail && (
        <span className="cv-worked__count acpmux-cloud-start__progress">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <span>{stage.detail}</span>
        </span>
      )}
    </div>
  );
}
