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
import { useContext, useId } from "react";
import { AgentTag } from "../conversation/AgentTag";
import { ChevronRight } from "../conversation/icons";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";

import { SubagentNavContext, SubagentPaneContext } from "./subagentGroupModel";
import { AgentIdentity } from "./AgentIdentity";
import { SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { agentTone } from "./agentTones";
import { type ReportRowLook } from "./reportRow.experiment";

import "./SubagentReportLine.css";
import { reportFallback, reportSender } from "./subagentReportLineModel";
import { useWholeReport } from "./wholeReport";
import { WholeReportBody } from "./WholeReportBody";
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
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const agent = row.subagentReport;
  // Read only while open: a closed line never walks the subagent's transcript.
  const report = useWholeReport(agent, expanded, expanded ? reportFallback(row) : undefined);
  const openView = agent && (pane ?? nav) ? () => (pane ?? nav)!(agent.id) : undefined;
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
      {expanded && report && (
        <div id={id} className="cv-subagent-report__body">
          <WholeReportBody report={report} className="selectable" onOpenView={openView} />
        </div>
      )}
    </div>
  );
}
