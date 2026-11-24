import type { AcpmuxSnapshot } from "./model";
import type { Translate } from "./i18n";
import { withoutSkillDollars, type SkillCatalog } from "./slashCommands";
import { retryErrorDetail, retryErrorSummary } from "./subagents/retryState";

export type QueuedEntry = AcpmuxSnapshot["queue"][number];

/// The text a row shows, whole: the prompt, or for acpmux's resume of a subagent its label, name and
/// cause, with its error's readable sentences under them. Never the resume's raw prompt, which names
/// the agent id and tells the agent how to resume it, nor the error's host and request id (cmux#51938).
export function shownText(entry: QueuedEntry, t: Translate, skills?: SkillCatalog): string {
  const retry = entry.retry;
  if (!retry) return withoutSkillDollars(entry.prompt, skills);
  const why = retryErrorSummary(t, retry.error);
  const name = `${t("composer.queuedSubagentRetry")} ${retry.name ?? retry.agentId ?? ""}`.trim();
  return [why ? `${name} · ${why}` : name, retryErrorDetail(retry.error)].filter(Boolean).join("\n");
}

/// Why a held prompt waits, by what the person can do about it (RFD 0026, machine 2's `Held`).
/// `trust` needs them: the folder's trust question is theirs to answer. `wait` needs nothing: the
/// Cloud machine is waking (cloudWake.ts) and the prompt goes once the chat is back; a host that is
/// still starting would join it, being the same "nothing to do" row (no data source names it yet).
/// Undefined: not held, the row is an ordinary queued prompt.
export type HeldReason = "trust" | "wait";

export function heldReason(entry: Pick<QueuedEntry, "held" | "waking">): HeldReason | undefined {
  if (!entry.held) return undefined;
  return entry.waking ? "wait" : "trust";
}
