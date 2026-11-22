import { createContext, useContext } from "react";
import { type Translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { subagentTaskLabel } from "./subsessions";
import { shownOfCut } from "../conversation/markdownCut";
import { reportRowLook, type ReportRowLook } from "./reportRow.experiment";
import { experimentArm } from "../../../experiments/experiment";

/// The look a gallery variant pins; the pane leaves it unset and reads the experiment's arm.
export const ReportRowLookContext = createContext<ReportRowLook | undefined>(undefined);

/// The report row's look: the variant's, else the experiment's arm.
export function useReportRowLook(): ReportRowLook {
  return useContext(ReportRowLookContext) ?? experimentArm(reportRowLook);
}

/// Whether a background turn's line is a subagent's report: Claude Code started it with a
/// subagent's task notification.
export const isSubagentReport = (row: AcpmuxRow): boolean => row.background?.cause?.kind === "subagent";

/// acpmux's cap on a notification's summary (hub/background_cause.rs), which it cuts with no mark.
const SUMMARY_CHARS = 240;

/// What the report says when the subagent left no output (wholeReport.ts reads its reply): why it
/// failed, else the notification's summary, its whole blocks when acpmux cut it.
export function reportFallback(row: AcpmuxRow): string | undefined {
  const error = row.subagentReport?.error?.trim();
  if (error) return error;
  const summary = row.background?.cause?.summary?.trim();
  if (!summary) return undefined;
  return Array.from(summary).length >= SUMMARY_CHARS ? shownOfCut(summary) : summary;
}

/// Who sent it: the subagent's task, as its "Subagent finished" line names it, else "Subagent".
export const reportSender = (t: Translate, row: AcpmuxRow): string =>
  row.subagentReport ? subagentTaskLabel(t, row.subagentReport) : t("tray.kind.subagent");
