import type { ReactNode } from "react";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { StatusGlyph } from "../../ui/StatusGlyph";
import type { Strings } from "../shared/i18n";
import { HomeIcon } from "./icons";
import type { HomeChiefWork } from "./chiefWorkTypes";
import "./chiefWork.css";

export interface ChiefWorkPanelProps {
  snapshot?: HomeChiefWork;
  loading: boolean;
  error?: string;
  onRefresh(): void;
  onClose(): void;
  strings: Strings;
}

const agentRank = { waiting: 0, working: 1, failed: 2, idle: 3 };
const taskRank = { running: 0, unknown: 1, failed: 2, cancelled: 2, done: 2 };

/** A snapshot view: no timers, subscriptions or parallel copy of the Chief's work state. */
export function ChiefWorkPanel({ snapshot, loading, error, onRefresh, onClose, strings }: ChiefWorkPanelProps) {
  const { t } = strings;
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
            {error
              ? t("work.unavailable")
              : loading
                ? t("work.loading")
                : snapshot?.truncated
                  ? t("work.partial")
                  : null}
          </output>
          {snapshot && agents.length === 0 && tasks.length === 0 && !snapshot.truncated && !error ? (
            <p className="hc-chief-work__empty">{t("work.empty")}</p>
          ) : (
            <>
              {agents.length > 0 && (
                <section aria-label={t("work.subagents")}>
                  <h3>{t("work.subagents")}</h3>
                  <ul>
                    {agents.map((agent) => (
                      <li key={agent.id} className="hc-chief-work__row" data-state={agent.state}>
                        <Mark state={agent.state} />
                        <div className="hc-chief-work__text">
                          <span className="hc-chief-work__name" title={agent.name}>
                            {agent.name}
                          </span>
                          {agent.task && <p>{agent.task}</p>}
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

function TaskRow({ task, strings }: { task: HomeChiefWork["tasks"][number]; strings: Strings }) {
  const { t } = strings;
  return (
    <li className="hc-chief-work__row" data-state={task.status}>
      <Mark state={task.status} />
      <div className="hc-chief-work__text">
        {task.command || task.detail ? (
          <details>
            <summary className="hc-chief-work__name" title={task.title}>
              {task.title}
            </summary>
            {task.command && <pre>{task.command}</pre>}
            {task.detail && <p className="hc-chief-work__detail">{task.detail}</p>}
          </details>
        ) : (
          <span className="hc-chief-work__name" title={task.title}>
            {task.title}
          </span>
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
