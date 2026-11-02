// The line of a run of one-line rows that carries messages between agents (messageRuns.ts): "Sent 5
// messages, ran 2 commands, read a file", drawn as a folded tool run's line is (ToolRun.tsx: the
// glyph in the tool rows' column, the summary, a failure count, then the chevron, lit on hover or
// while open). A click opens the run's rows under it, which the transcript draws as its own rows
// (turns.ts), so the open state is the transcript's fold set, kept per chat like a "Worked for"
// fold, and survives virtualization.
import { useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { useToolRunLook } from "../toolRunLook";
import { ChevronRight, Envelope, Spinner } from "./icons";
import { messageRunSummary } from "./messageRuns";
import { ToolLabel } from "./ToolVerb";

export function MessageRunLine({
  row,
  expanded,
  onToggle,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  onToggle: () => void;
}) {
  const t = useT();
  const look = useToolRunLook();
  const run = row.messageRun;
  const summary = useMemo(() => (run ? messageRunSummary(t, run) : ""), [t, run]);
  if (!run) return null;
  const quiet = look === "quiet" || look === "quiet-pencil";
  return (
    <div className="cv-tools">
      <button
        type="button"
        className={quiet ? "cv-tool is-toggle is-run" : "cv-tool is-toggle is-run is-strong"}
        aria-expanded={expanded}
        data-message-run=""
        data-find-skip=""
        onClick={onToggle}
      >
        <span className="cv-tool__icon">{run.running ? <Spinner size={16} /> : <Envelope />}</span>
        <span className="cv-tool__text">
          <span className="cv-tool__summary">
            <ToolLabel text={summary} />
          </span>
          {run.failed > 0 && <span className="cv-tool__failed"> {t("tools.failedCount", { n: run.failed })}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${expanded ? " is-open" : " is-hover"}`}
        />
      </button>
    </div>
  );
}
