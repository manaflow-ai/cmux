import type { ReactNode } from "react";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { StatusGlyph } from "../../ui/StatusGlyph";
import type { Strings } from "../shared/i18n";
import { HomeIcon } from "./icons";
import type { HomeChiefWork, HomeChiefAgent, HomeChiefPlan } from "./chiefWorkTypes";
import { useExperimentArm } from "../../experiments/useExperimentArm";
import { chiefPlans, type ChiefPlansArm } from "./chiefPlans.experiment";
import "./chiefWork.css";

export interface ChiefWorkPanelProps {
  snapshot?: HomeChiefWork;
  loading: boolean;
  /** The read has failed for the house deadline and is still being asked again (`useAutoRetry`): one
   *  quiet line, no button. Earlier failures show nothing. */
  stillTrying?: boolean;
  onRefresh(): void;
  onClose(): void;
  strings: Strings;
  /** The plans arm; else the `chief-plans` experiment's (default off). */
  plans?: ChiefPlansArm;
}

const agentRank = { waiting: 0, working: 1, failed: 2, idle: 3 };
const taskRank = { running: 0, unknown: 1, failed: 2, cancelled: 2, done: 2 };

/** A snapshot view: no timers, subscriptions or parallel copy of the Chief's work state. */
export function ChiefWorkPanel({
  snapshot,
  loading,
  stillTrying,
  onRefresh,
  onClose,
  strings,
  plans,
}: ChiefWorkPanelProps) {
  const { t } = strings;
  const experimentPlans = useExperimentArm(chiefPlans);
  const arm = plans ?? experimentPlans;
  const agents = [...(snapshot?.agents ?? [])].sort(
    (a, b) => agentRank[a.state] - agentRank[b.state] || (a.startedAt ?? 0) - (b.startedAt ?? 0),
  );
  const tasks = [...(snapshot?.tasks ?? [])].sort(
    (a, b) =>
      taskRank[a.status] - taskRank[b.status] ||
      (a.status === "running" ? (a.startedAt ?? 0) - (b.startedAt ?? 0) : (b.endedAt ?? 0) - (a.endedAt ?? 0)),
  );
  const activeTasks = tasks.filter((task) => task.status === "running" || task.status === "unknown");
  const finishedTasks = tasks.filter((task) => task.status !== "running" && task.status !== "unknown");
  const commands = snapshot?.taskSources?.length === 1 && snapshot.taskSources[0] === "harness";
  return (
    <KeyboardScope
      className="hc-chief-work-scope"
      handleKeyDown={(event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          onClose();
        }
      }}
    >
      <aside className="lg-sheet hc-chief-work" aria-label={t("work.open")} aria-busy={loading}>
        <header className="hc-chief-work__header">
          <div>
            <h2>{t("work.open")}</h2>
            <p>{t(commands ? "work.harnessScope" : "work.scope")}</p>
          </div>
          <button type="button" className="hc-chief-work__refresh" disabled={loading} onClick={onRefresh}>
            {t("work.refresh")}
          </button>
          <button type="button" className="hc-chief-work__close" aria-label={t("work.close")} onClick={onClose}>
            <HomeIcon name="close" size={16} />
          </button>
        </header>
        <div className="hc-chief-work__body">
          <output className="hc-chief-work__notice">
            {stillTrying
              ? t("work.stillLoading")
              : loading
                ? t("work.loading")
                : snapshot?.truncated
                  ? t("work.partial")
                  : null}
          </output>
          {snapshot && agents.length === 0 && tasks.length === 0 && !snapshot.truncated && !stillTrying ? (
            <p className="hc-chief-work__empty">{t("work.empty")}</p>
          ) : (
            <>
              {arm === "section" && <PlansSection snapshot={snapshot} agents={agents} strings={strings} />}
              {agents.length > 0 && (
                <section aria-label={t("work.subagents")}>
                  <h3>{t("work.subagents")}</h3>
                  <ul>
                    {agents.map((agent) => (
                      <li key={agent.id} className="hc-chief-work__row" data-state={agent.state}>
                        <Mark state={agent.state} />
                        <div className="hc-chief-work__text">
                          <span className="hc-chief-work__name">{agent.name}</span>
                          {agent.task && <p>{agent.task}</p>}
                          {(arm === "inline" || arm === "steps") && agent.plan && agent.plan.total > 0 && (
                            <PlanLine plan={agent.plan} strings={strings} look={arm} />
                          )}
                        </div>
                        <span className="hc-chief-work__state">
                          {t(
                            agent.state === "working"
                              ? "chief.working"
                              : agent.state === "waiting"
                                ? "work.waiting"
                                : agent.state === "failed"
                                  ? "run.status.failed"
                                  : "chief.idle",
                          )}
                        </span>
                      </li>
                    ))}
                  </ul>
                </section>
              )}
              {tasks.length > 0 && (
                <section aria-label={t(commands ? "work.backgroundCommands" : "work.backgroundTasks")}>
                  <h3>{t(commands ? "work.backgroundCommands" : "work.backgroundTasks")}</h3>
                  {activeTasks.length > 0 && (
                    <ul>
                      {activeTasks.map((task) => (
                        <TaskRow key={`${task.sessionId}:${task.id}`} task={task} strings={strings} />
                      ))}
                    </ul>
                  )}
                  {finishedTasks.length > 0 && (
                    <details className="hc-chief-work__finished">
                      <summary>
                        {t("work.finished")} <span>{finishedTasks.length.toLocaleString(strings.language)}</span>
                      </summary>
                      <ul>
                        {finishedTasks.map((task) => (
                          <TaskRow key={`${task.sessionId}:${task.id}`} task={task} strings={strings} />
                        ))}
                      </ul>
                    </details>
                  )}
                </section>
              )}
            </>
          )}
        </div>
      </aside>
    </KeyboardScope>
  );
}

/** The Chief's own plans, then each subagent's, ahead of everything else. */
function PlansSection({
  snapshot,
  agents,
  strings,
}: {
  snapshot?: HomeChiefWork;
  agents: readonly HomeChiefAgent[];
  strings: Strings;
}) {
  const { t } = strings;
  const rows = [...(snapshot?.plans ?? []), ...agents].filter(
    (row): row is HomeChiefAgent & { plan: HomeChiefPlan } => !!row.plan && row.plan.total > 0,
  );
  if (rows.length === 0) return null;
  return (
    <section aria-label={t("work.plans")} className="hc-chief-work__plans">
      <h3>{t("work.plans")}</h3>
      <ul>
        {rows.map((row) => (
          <li key={row.id} className="hc-chief-work__row" data-state={row.state}>
            <Mark state={row.plan.done >= row.plan.total ? "done" : row.state} />
            <div className="hc-chief-work__text">
              <span className="hc-chief-work__name">{row.name}</span>
              <PlanLine plan={row.plan} strings={strings} look="steps" />
            </div>
            <span className="hc-chief-work__state">{progress(row.plan, strings)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function progress(plan: HomeChiefPlan, strings: Strings): string {
  const n = (value: number) => value.toLocaleString(strings.language);
  return `${n(Math.min(plan.done, plan.total))}/${n(plan.total)}`;
}

/** One chat's plan: `inline` is the count and the step in progress on one line; `steps` adds a
 *  progress bar and the next step. */
function PlanLine({ plan, strings, look }: { plan: HomeChiefPlan; strings: Strings; look: "inline" | "steps" }) {
  const { t } = strings;
  const done = Math.min(plan.done, plan.total);
  if (look === "inline")
    return (
      <p className="hc-chief-work__plan" data-look="inline">
        <span className="hc-chief-work__plan-count">{progress(plan, strings)}</span>
        {plan.current && <span className="hc-chief-work__plan-step">{plan.current}</span>}
      </p>
    );
  return (
    <div className="hc-chief-work__plan" data-look="steps">
      <progress max={plan.total} value={done} aria-label={progress(plan, strings)} />
      {plan.current && (
        <p>
          <span className="hc-chief-work__plan-label">{t("work.planNow")}</span> {plan.current}
        </p>
      )}
      {plan.next && (
        <p className="hc-chief-work__plan-next">
          <span className="hc-chief-work__plan-label">{t("work.planNext")}</span> {plan.next}
        </p>
      )}
    </div>
  );
}

function TaskRow({ task, strings }: { task: HomeChiefWork["tasks"][number]; strings: Strings }) {
  const { t } = strings;
  return (
    <li className="hc-chief-work__row" data-state={task.status}>
      <Mark state={task.status} />
      <div className="hc-chief-work__text">
        {task.command || task.detail ? (
          <details>
            <summary className="hc-chief-work__name">{task.title}</summary>
            {task.command && <pre>{task.command}</pre>}
            {task.detail && <p className="hc-chief-work__detail">{task.detail}</p>}
          </details>
        ) : (
          <span className="hc-chief-work__name">{task.title}</span>
        )}
      </div>
      <span className="hc-chief-work__state">
        {t(task.status === "unknown" ? "work.unknown" : `run.status.${task.status}`)}
      </span>
    </li>
  );
}

function Mark({ state }: { state: string }): ReactNode {
  if (state === "working" || state === "running") return <Spinner size={10} />;
  return (
    <StatusGlyph
      name={state === "failed" ? "error" : state === "done" ? "done" : state === "waiting" ? "waiting" : "idle"}
      size={12}
    />
  );
}
