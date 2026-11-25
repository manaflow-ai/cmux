// Plans: every agent's plan at once, one card each: its steps as acpmux keeps them (the harness's
// TodoWrite or update_plan, or a list its agent or Chief set), the step in progress marked, done of
// total, and who set it when it is not the harness. Below, what is running without a plan. The
// counts and lines come from acpmux (task_list.rs); this view only draws them.
import { memo, useMemo } from "react";
import { plansBoard, sameRowProps } from "../model";
import { AgentRow, agentsOf, Ago, Loaded, machineLabel, StateMark } from "../parts";
import type { ChiefViewProps } from "../registry";
import type { ChiefAgent, ChiefPlanStatus } from "../types";

const MARK: Record<ChiefPlanStatus, string> = { completed: "✓", in_progress: "▸", pending: "○" };

export function PlansView({ data, strings, placement, onOpenAgent }: ChiefViewProps) {
  const agents = agentsOf(data);
  const board = useMemo(() => plansBoard(agents), [agents]);
  const compact = placement === "sidebar";
  return (
    <Loaded status={data.agents.status} strings={strings}>
      <div className="cv-plans">
        {board.planned.length === 0 ? (
          <p className="cv-note">{strings.t("chiefViews.plans.empty")}</p>
        ) : (
          <ul className="cv-plan-cards">
            {board.planned.map((agent) => (
              <PlanCard
                key={`${agent.kind}:${agent.id}`}
                agent={agent}
                strings={strings}
                compact={compact}
                onOpen={onOpenAgent}
              />
            ))}
          </ul>
        )}
        {board.unplanned.length > 0 && (
          <section className="cv-machine" aria-label={strings.t("chiefViews.plans.noPlan")}>
            <h3 className="cv-machine-head">
              <span className="cv-machine-name">{strings.t("chiefViews.plans.noPlan")}</span>
              <span className="cv-machine-count">{board.unplanned.length}</span>
            </h3>
            <ul className="cv-rows">
              {board.unplanned.map((agent) => (
                <AgentRow
                  key={`${agent.kind}:${agent.id}`}
                  agent={agent}
                  strings={strings}
                  compact={compact}
                  showMachine
                  onOpen={onOpenAgent}
                />
              ))}
            </ul>
          </section>
        )}
      </div>
    </Loaded>
  );
}

/** One agent's plan. A sidebar drops the done steps: the count says them. It draws again only
 * when its own agent changed. */
const PlanCard = memo(function PlanCard({
  agent,
  strings,
  compact,
  onOpen,
}: {
  agent: ChiefAgent;
  strings: ChiefViewProps["strings"];
  compact: boolean;
  onOpen: (agent: ChiefAgent) => void;
}) {
  const plan = agent.plan!;
  const steps = compact ? plan.steps.filter((step) => step.status !== "completed") : plan.steps;
  const finished = plan.done >= plan.total;
  return (
    <li className="cv-plan-card" data-state={agent.state} data-finished={finished ? "" : undefined}>
      <button type="button" className="cv-plan-head" onClick={() => onOpen(agent)}>
        <StateMark state={agent.state} strings={strings} />
        <span className="cv-row-title">{agent.title}</span>
        <span className="cv-row-machine">{machineLabel(agent, strings)}</span>
        {plan.source !== "harness" && (
          <span className="cv-chip cv-plan-source">{strings.t(`chiefViews.plans.source.${plan.source}`)}</span>
        )}
        <span
          className="cv-plan-progress"
          aria-label={strings.format("chiefViews.plans.progress", `${plan.done}`, `${plan.total}`)}
        >
          <span className="cv-plan-count">
            {plan.done}/{plan.total}
          </span>
          <span className="cv-plan-bar" aria-hidden="true">
            <span className="cv-plan-fill" style={{ inlineSize: `${(plan.done / plan.total) * 100}%` }} />
          </span>
        </span>
        <Ago at={plan.updatedAt ?? agent.lastOutputAt} strings={strings} />
      </button>
      {steps.length > 0 ? (
        <ol className="cv-plan-steps">
          {steps.map((step, index) => (
            <li key={index} className="cv-plan-step" data-status={step.status}>
              <span className="cv-plan-mark" aria-label={strings.t(`chiefViews.plans.step.${step.status}`)}>
                {MARK[step.status]}
              </span>
              <span className="cv-plan-text">{step.content}</span>
            </li>
          ))}
        </ol>
      ) : (
        // An app or acpmux older than the steps: acpmux's two lines still say where it is.
        (plan.current || plan.next) && (
          <ol className="cv-plan-steps">
            {plan.current && (
              <li className="cv-plan-step" data-status="in_progress">
                <span className="cv-plan-mark">{MARK.in_progress}</span>
                <span className="cv-plan-text">{plan.current}</span>
              </li>
            )}
            {plan.next && (
              <li className="cv-plan-step" data-status="pending">
                <span className="cv-plan-mark">{MARK.pending}</span>
                <span className="cv-plan-text">{plan.next}</span>
              </li>
            )}
          </ol>
        )
      )}
    </li>
  );
}, sameRowProps);
