import type { AcpmuxSnapshot } from "./model";
import type { Translate } from "./i18n";
import { withoutSkillDollars, type SkillCatalog } from "./slashCommands";

export type QueuedEntry = AcpmuxSnapshot["queue"][number];

/// The text a row shows, whole: the prompt, or for acpmux's resume of a subagent its label, name and
/// error. Never the resume's raw prompt, which names the agent id and tells the agent how to resume it.
export function shownText(entry: QueuedEntry, t: Translate, skills?: SkillCatalog): string {
  const retry = entry.retry;
  if (!retry) return withoutSkillDollars(entry.prompt, skills);
  return [`${t("composer.queuedSubagentRetry")} ${retry.name ?? retry.agentId ?? ""}`.trim(), retry.error]
    .filter(Boolean)
    .join("\n");
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

/// Each queued prompt once, in order: a second entry under an id already seen is dropped, so a
/// prompt acpmux listed twice (a replayed or restored record) never draws twice.
export function uniqueById<T extends { id: string }>(entries: readonly T[]): T[] {
  const seen = new Set<string>();
  return entries.filter((entry) => !seen.has(entry.id) && seen.add(entry.id));
}

/// The queue's one-line summary: how many wait and that they go in order and can still be edited
/// or removed. It names what the list holds, never a bare count.
export function queueSummary(count: number, t: Translate): string {
  return t("composer.queueSummary", { n: count });
}
