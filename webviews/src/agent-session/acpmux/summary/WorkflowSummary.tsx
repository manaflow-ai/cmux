// l10n-allow-file: workflow labels are an experimental Labs surface; phase and agent names come
// from the future acpmux workflow contract and the small action labels reuse shipped strings.
import { useEffect, useMemo, useState } from "react";
import { formatDuration } from "../conversation/turns";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { WorkflowAgent, WorkflowSummary } from "./workflow";

export type WorkflowActions = {
  onPause?: () => void;
  onStop?: () => void;
  onSave?: () => void;
  onOpenTranscript?: (rowId: string) => void;
};

export function WorkflowSummaryRow({
  workflow,
  actions = {},
}: {
  workflow?: WorkflowSummary;
  actions?: WorkflowActions;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const selectedAgentPhaseId = workflow?.selectedAgentId
    ? workflow.phases.find((entry) => entry.agentIds.includes(workflow.selectedAgentId!))?.id
    : undefined;
  const preferredPhaseId = workflow?.phase ?? selectedAgentPhaseId ?? workflow?.phases[0]?.id;
  const [phaseId, setPhaseId] = useState(preferredPhaseId);
  useEffect(() => setPhaseId(preferredPhaseId), [preferredPhaseId]);
  const phase = useMemo(
    () => workflow?.phases.find((entry) => entry.id === phaseId) ?? workflow?.phases[0],
    [phaseId, workflow],
  );
  if (!workflow) return null;
  const completed = workflow.agents.filter((agent) => agent.state === "completed").length;
  const selected = workflow.agents.find((agent) => agent.id === workflow.selectedAgentId) ?? workflow.agents[0];
  const stateLabel =
    workflow.state === "running"
      ? t("subagents.state.running")
      : workflow.state === "completed"
        ? t("subagents.state.completed")
        : workflow.state === "failed"
          ? t("subagents.state.failed")
          : workflow.state === "paused"
            ? t("goal.paused")
            : t("plan.status.pending");
  const state =
    workflow.state === "running" ? <Spinner size={12} loading /> : <Icon name="agent.session" size={12} row />;
  return (
    <section className="acpmux-summary-section acpmux-workflow" aria-label={workflow.title} data-state={workflow.state}>
      <button
        type="button"
        className="acpmux-summary-row acpmux-summary-link acpmux-workflow__row"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span className="acpmux-workflow__icon" data-state={workflow.state}>
          {state}
        </span>
        <span className="acpmux-summary-text acpmux-workflow__title">{workflow.title}</span>
        <span className="acpmux-workflow__state" aria-label={`${workflow.title}: ${stateLabel}`}>
          {stateLabel}
        </span>
        {workflow.phase && <span className="acpmux-summary-meta">{workflow.phases.find((entry) => entry.id === workflow.phase)?.name}</span>}
        <span className="acpmux-summary-meta">
          {completed}/{workflow.agents.length}
          {workflow.elapsedMs !== undefined && ` · ${formatDuration(workflow.elapsedMs)}`}
          {workflow.tokens !== undefined &&
            ` · ${t("subagents.tokens", { n: workflow.tokens, tokens: workflow.tokens })}`}
        </span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={10} />
      </button>
      {open && (
        <div className="acpmux-workflow__detail">
          {workflow.large && (
            <p className="acpmux-workflow__warning" role="alert">
              Large workflow
            </p>
          )}
          <div className="acpmux-workflow__columns">
            <div className="acpmux-workflow__phases">
              <h4>Phases</h4>
              {workflow.phases.map((entry) => (
                <button
                  type="button"
                  key={entry.id}
                  className="acpmux-workflow__phase"
                  data-state={entry.state}
                  aria-pressed={entry.id === phase?.id}
                  onClick={() => setPhaseId(entry.id)}
                >
                  <span>{entry.name}</span>
                  <span>{entry.state}</span>
                </button>
              ))}
            </div>
            <div className="acpmux-workflow__agents" role="list" aria-label={t("summary.subagents.active", { n: workflow.agents.length })}>
              <h4>{phase?.name ?? t("summary.subagents.active", { n: workflow.agents.length })}</h4>
              {(phase ? workflow.agents.filter((agent) => phase.agentIds.includes(agent.id)) : workflow.agents).map(
                (agent) => (
                  <div
                    className="acpmux-workflow__agent"
                    key={agent.id}
                    data-state={agent.state}
                    data-selected={agent.id === selected?.id || undefined}
                    role="listitem"
                    aria-current={agent.id === selected?.id ? "true" : undefined}
                  >
                    <span className="acpmux-workflow__agent-icon">
                      {agent.state === "running" ? (
                        <Spinner size={12} loading />
                      ) : (
                        <Icon name="agent.session" size={12} row />
                      )}
                    </span>
                    <span className="acpmux-summary-text">
                      <span>{agent.name}</span>
                      {agent.doing && <span className="acpmux-workflow__doing">{agent.doing}</span>}
                    </span>
                    <span className="acpmux-summary-meta">
                      {agent.state === "pending" || agent.state === "waiting"
                        ? t("subagents.state.waiting")
                        : agent.state === "running"
                          ? t("subagents.state.running")
                          : agent.state === "completed"
                            ? t("subagents.state.completed")
                            : t("subagents.state.failed")}
                    </span>
                    {agent.tokens !== undefined && <span className="acpmux-summary-meta">{agent.tokens}</span>}
                    {agent.transcriptRowId && actions.onOpenTranscript && (
                      <button
                        type="button"
                        className="acpmux-workflow__transcript"
                        aria-label={`Open transcript for ${agent.name}`}
                        onClick={() => actions.onOpenTranscript?.(agent.transcriptRowId!)}
                      >
                        <Icon name="disclosure.collapsed" size={11} />
                      </button>
                    )}
                  </div>
                ),
              )}
              {selected && <span className="acpmux-workflow__selected">{selected.name}</span>}
            </div>
          </div>
          {(actions.onPause || actions.onStop || actions.onSave) && (
            <div className="acpmux-workflow__actions">
              {actions.onPause && (
                <button type="button" onClick={actions.onPause}>
                  {t("replay.pause")}
                </button>
              )}
              {actions.onStop && (
                <button type="button" onClick={actions.onStop}>
                  {t("subagents.stop", { name: workflow.title })}
                </button>
              )}
              {actions.onSave && (
                <button type="button" onClick={actions.onSave}>
                  {t("artifact.save")}
                </button>
              )}
            </div>
          )}
          {!actions.onPause && !actions.onStop && !actions.onSave && (
            <div className="acpmux-workflow__actions" aria-label={t("summary.empty")}>
              <button type="button" disabled aria-disabled="true">
                {t("replay.pause")}
              </button>
              <button type="button" disabled aria-disabled="true">
                {t("subagents.stop", { name: workflow.title })}
              </button>
              <button type="button" disabled aria-disabled="true">
                {t("artifact.save")}
              </button>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
