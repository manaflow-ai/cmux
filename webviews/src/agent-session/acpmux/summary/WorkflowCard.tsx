// A Claude workflow's card in the transcript, where it started (Labs `workflowLabs`; the row is
// subagents/runningTray.ts `WORKFLOW_CARD`): its name, "Workflow · 6 agents · 13s" and a dot per
// agent, live while it runs. A click opens Session Info's Background tasks, which lists its phases
// and agents (inspector/WorkflowTasks.tsx). Its height is fixed: the dots stay on one line, so a
// running clock or a new agent never moves the transcript.
import { useMemo, useSyncExternalStore } from "react";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { useNow } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import { tally, workflowOf } from "./foldWorkflows";
import "./WorkflowCard.css";
import "./workflowDots.css";

/// Opens Session Info's Background tasks for workflow `id`; absent, the card is no button. The pane
/// sets it as its Inspector comes and goes (App.tsx), as subagents/runningTray.ts's switch is set.
let opener: ((id: string) => void) | undefined;
const listeners = new Set<() => void>();
export function configureWorkflowCardOpen(open: ((id: string) => void) | undefined): void {
  if (open === opener) return;
  opener = open;
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => opener;

export function WorkflowCard({ node }: { node: Subagent }) {
  const t = useT();
  const open = useSyncExternalStore(subscribe, current, current);
  const workflow = useMemo(() => workflowOf(node, ""), [node]);
  const running = workflow.state === "running";
  const now = useNow(running);
  const elapsed = workflow.elapsedMs ?? Math.max(0, now - workflow.startedAt!);
  const total = tally(workflow.agents).total || (workflow.counts?.started ?? 0);
  return (
    <button
      type="button"
      className="acpmux-workflow-card"
      data-state={workflow.state}
      disabled={!open}
      onClick={() => open?.(node.id)}
    >
      <span className="acpmux-workflow-card__head">
        <span className="acpmux-workflow-card__name">{workflow.title}</span>
        <Icon name="disclosure.collapsed" size={11} />
      </span>
      <span className="acpmux-workflow-card__meta">
        <span>{t("workflow.kind")}</span>
        {total > 0 && <span>{t("subagents.pill", { n: total })}</span>}
        <span>{formatDuration(elapsed)}</span>
      </span>
      <span className="acpmux-workflow-dots acpmux-workflow-card__dots" aria-hidden="true">
        {workflow.agents.map((agent) => (
          <span key={agent.id} className="acpmux-workflow-dot" data-state={agent.state} />
        ))}
      </span>
    </button>
  );
}
