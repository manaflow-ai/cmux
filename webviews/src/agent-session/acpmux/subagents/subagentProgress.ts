// What a subagent has spent so far, as the parts of its status line: a Claude workflow's agents
// done of started, its tokens and its tool uses (acpmux `subagent_progress`, subagentFold.ts).
// The transcript's subagent rows draw it; a list of subagents elsewhere should too, so each says
// the same thing the same way.
import type { PaneLanguage, Translate } from "../i18n";
import type { Subagent } from "./subagentFold";

/// The progress parts that apply, in order; none until the harness reports any.
/// `usage: false` leaves out its tokens and tool uses: the tray's and transcript's subagent rows
/// read like Claude Code's, its title and state (Leo, 2026-10-31: "we can remove the symbols and the
/// tokens"); Session Info's Context still says them.
export function subagentProgress(
  t: Translate,
  language: PaneLanguage,
  agent: Subagent,
  { usage = true }: { usage?: boolean } = {},
): string[] {
  const parts: string[] = [];
  if (agent.agents && agent.agents.started > 0)
    parts.push(t("subagents.workflowAgents", { n: agent.agents.started, done: agent.agents.done }));
  if (agent.agents?.failed && agent.agents.failed > 0)
    parts.push(t("summary.subagents.failed", { n: agent.agents.failed }));
  if (agent.agents?.queued && agent.agents.queued > 0) parts.push(t("workflow.queued", { n: agent.agents.queued }));
  if (usage && agent.tokens)
    parts.push(
      t("subagents.tokens", {
        n: agent.tokens,
        tokens: new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(agent.tokens),
      }),
    );
  if (usage && agent.toolUses) parts.push(t("subagents.toolUses", { n: agent.toolUses }));
  return parts;
}
