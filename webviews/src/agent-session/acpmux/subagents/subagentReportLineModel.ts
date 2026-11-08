import { createContext, useContext } from "react";
import { type Translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { subagentTaskLabel } from "./subsessions";
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
