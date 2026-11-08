import { createContext } from "react";
import { type DoneReportLook } from "./doneReport.experiment";

/// Where a failed line's Retry sits: an inline button (the default), a link after the line's
/// time, or only in the ⋯ menu. The gallery compares them (SubagentRetry.gallery.tsx).
export type RetryAffordance = "button" | "link" | "menu";
export const RetryAffordanceContext = createContext<RetryAffordance>("button");

/// The report's look a gallery variant pins (SubagentDoneLine.gallery.tsx); the pane leaves it
/// unset and reads the experiment's arm.
export const DoneReportLookContext = createContext<DoneReportLook | undefined>(undefined);

/// What a finished subagent reported, for its line: its final reply, else its last message. Only
/// a completed line has one to show; a failed, stopped or retrying line says why on the line.
export function doneReport(agent: { state: string; result?: string; lastMessage?: string }): string | undefined {
  if (agent.state !== "completed") return undefined;
  return (agent.result ?? agent.lastMessage)?.trim() || undefined;
}

/// A failure's reason as a failed line shows it: its first sentence, the rest in the tooltip and the
/// button's name ("Agent terminated early due to an API error. Retry with …" reads its first part).
export function shortReason(error: string): string {
  const line = error.trim().split("\n")[0]!.trim();
  const sentence = /^(.+?[.!?])(?:\s|$)/u.exec(line);
  return (sentence ? sentence[1]! : line).replace(/[.]$/u, "");
}
