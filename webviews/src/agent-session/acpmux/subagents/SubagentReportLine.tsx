// A subagent's report to its chat (Leo, 2026-11-05, on a clock-icon line under "Subagent finished"
// that read the report's first words: "what's up with this \"tool call\"?"). When a subagent ends,
// Claude Code hands the chat its report as a task notification, which starts a turn the agent runs
// on its own (acpmux `background_turn`, its `cause.kind` `subagent`). That turn's line said the
// notification's summary with a clock, in a tool row's grammar. Here it says whose report it is,
// "Report from Fix live working line", right under that subagent's "Subagent finished" line
// (runningTray.ts `withSubagentLines` puts them together), and opens to the report in the
// transcript's Markdown, as a reply reads, then the agent's own reply to it (the turn's rows).
// Only a Claude subagent's report draws this way; every other background turn keeps its line
// (BackgroundTurnLine.tsx). How it draws is an experiment (reportRow.experiment.ts).
import { createContext, useContext, useId } from "react";
import { AgentTag } from "../conversation/AgentTag";
import { Markdown } from "../conversation/Markdown";
import { ChevronRight } from "../conversation/icons";
import { useT, type Translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { subagentTaskLabel } from "./subsessions";
import { SubagentViewsContext } from "./SubagentGroup";
import { AgentIdentity, SUBAGENT_FALLBACK } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import { reportRowLook, type ReportRowLook } from "./reportRow.experiment";
import { experimentArm } from "../../../experiments/experiment";
import "./SubagentReportLine.css";

/// The look a gallery variant pins; the pane leaves it unset and reads the experiment's arm.
export const ReportRowLookContext = createContext<ReportRowLook | undefined>(undefined);

/// The report row's look: the variant's, else the experiment's arm.
export function useReportRowLook(): ReportRowLook {
  return useContext(ReportRowLookContext) ?? experimentArm(reportRowLook);
}

/// Whether a background turn's line is a subagent's report: Claude Code started it with a
/// subagent's task notification.
export const isSubagentReport = (row: AcpmuxRow): boolean => row.background?.cause?.kind === "subagent";

/// The last reply in a subagent's own transcript, whole.
function lastReply(view: readonly AcpmuxRow[] | undefined): string | undefined {
  for (let at = (view?.length ?? 0) - 1; at >= 0; at -= 1) {
    const entry = view![at]!;
    if (entry.kind === "assistant" && entry.text?.trim()) return entry.text;
  }
  return undefined;
}

/// What the report says, whole: the subagent's final reply (a sub-session's record, else the last
/// reply in its own transcript), else its last message or why it failed, else the notification's
/// summary. acpmux cuts a Claude subagent's `lastMessage` and the summary at 240 characters, so
/// they come only when nothing whole is there.
export function reportText(row: AcpmuxRow, view?: readonly AcpmuxRow[]): string | undefined {
  const agent = row.subagentReport;
  const text = agent?.result ?? lastReply(view) ?? agent?.lastMessage ?? agent?.error ?? row.background?.cause?.summary;
  return text?.trim() || undefined;
}

/// Who sent it: the subagent's task, as its "Subagent finished" line names it, else "Subagent".
export const reportSender = (t: Translate, row: AcpmuxRow): string =>
  row.subagentReport ? subagentTaskLabel(t, row.subagentReport) : t("tray.kind.subagent");

export function SubagentReportLine({
  row,
  look,
  expanded,
  onToggle,
}: {
  row: AcpmuxRow;
  look: Exclude<ReportRowLook, "before">;
  expanded: boolean;
  onToggle: () => void;
}) {
  const t = useT();
  const id = useId();
  const name = reportSender(t, row);
  const readView = useContext(SubagentViewsContext);
  // Read only while open: a closed line never walks the subagent's transcript.
  const text = expanded ? reportText(row, row.subagentReport && readView?.(row.subagentReport.id)) : undefined;
  const [before, after = ""] = t("subagents.report.from", { name: "\u0000" }).split("\u0000");
  const label = t("subagents.report.from", { name });
  const failed = row.background?.cause?.weight === "failure";
  // Right under its finished line it needs no mark of its own; anywhere else (a report delivered
  // again after a resume) it draws the subagent's mark in the icon column, so it still says whose.
  const under = row.subagentReportFirst === true;
  return (
    <div
      className="cv-subagent-report"
      data-look={look}
      data-under={under ? "" : undefined}
      data-state={failed ? "failed" : undefined}
      data-background-turn="report"
      data-find-skip=""
    >
      <button
        type="button"
        className="cv-subagent-report__head"
        aria-expanded={expanded}
        aria-controls={expanded ? id : undefined}
        aria-label={label}
        onClick={onToggle}
      >
        {!under && (
          <span className="cv-subagent-report__icon" aria-hidden="true">
            <AgentIdentity
              tone={row.subagentReport ? agentTone(row.subagentReport.id) : undefined}
              size={16}
              fallback={SUBAGENT_FALLBACK}
            />
          </span>
        )}
        <span className="cv-subagent-report__sentence">
          {before}
          <AgentTag name={name} />
          {after}
        </span>
        <span className="cv-subagent-report__chevron" aria-hidden="true">
          <ChevronRight size={12} className={`cv-rotor${expanded ? " is-open" : ""}`} />
        </span>
      </button>
      {expanded && text && (
        <div id={id} className="cv-subagent-report__body selectable">
          <Markdown>{text}</Markdown>
        </div>
      )}
    </div>
  );
}
