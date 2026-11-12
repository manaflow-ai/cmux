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
