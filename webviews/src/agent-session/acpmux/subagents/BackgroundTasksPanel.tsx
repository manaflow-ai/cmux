// PROTOTYPE (design decision, not wired into App.tsx): the right-pane "Background tasks" panel
// beside the chat, after Claude desktop's background tasks panel and the Codex app's Subagents tab.
// It lists the chat's running subagents and workflows (Subagent, subagentFold.ts) and the shells the
// agent runs in the background, with a collapsed "Finished N" section and a header with Clear all and
// close. Three layouts compete for the same data:
//   list     dense: the transcript's shared subagent row (SubagentListRow) for every agent, and a
//            shell row in the same shape
//   cards    one card per task, Claude desktop style: action, spend, View transcript, live output
//   grouped  28px rows grouped by kind (Workflows, Agents, Shells), shell output inline under its row
//   grouped2 C refined: agents and workflows on two lines (title, then action · spend), shells on
//            one 28px line, quiet group labels only when kinds mix, a filled stop square
// Stop, Remove from list and Clear all act at once on the panel's own copy (optimistic); every row
// has a right-click menu.
import { useContext, useState, type ReactNode } from "react";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { formatDuration } from "../conversation/turns";
import { usePaneLanguage, useT, type StringKey, type Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { AgentMark, agentBrand } from "../../shared/AgentMark";
import type { AcpmuxRow } from "../model";
import {
  STATE_LABEL,
  SubagentHarnessContext,
  SubagentListRow,
  SubagentPaneContext,
  SubagentStopContext,
  elapsed,
  useNow,
} from "./SubagentGroup";
import type { Subagent } from "./subagentFold";
import { subagentProgress } from "./subagentProgress";

/// A shell the agent runs in the background (Claude's Bash `run_in_background`), with the last
/// lines it printed.
export type BackgroundShell = {
  id: string;
  command: string;
  state: "running" | "completed" | "failed" | "stopped";
  startedAt: number;
  endedAt?: number;
  output: string[];
};

export type BackgroundTasksLayout = "list" | "cards" | "grouped" | "grouped2";

export type BackgroundTasksPanelProps = {
  layout: BackgroundTasksLayout;
  agents: Subagent[];
  shells: BackgroundShell[];
  /// The chat's harness, for the shared row's avatar mark.
  harness?: string;
  finishedOpen?: boolean;
  onOpen?: (id: string) => void;
  onClose?: () => void;
};

type Task = { type: "agent"; agent: Subagent } | { type: "shell"; shell: BackgroundShell };

const SHELL_STATE: Record<BackgroundShell["state"], StringKey> = {
  running: "bgTask.state.running",
  completed: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  stopped: "bgTask.state.stopped",
};

/// Lines of live output a shell shows.
const TAIL = 3;

const taskId = (task: Task) => (task.type === "agent" ? task.agent.id : task.shell.id);
const isRunning = (task: Task) => (task.type === "agent" ? task.agent.state : task.shell.state) === "running";
const isWorkflow = (agent: Subagent) => agent.agents !== undefined;
const startedAt = (task: Task) => (task.type === "agent" ? task.agent.startedAt : task.shell.startedAt);
const shellElapsed = (shell: BackgroundShell, now: number) => Math.max(0, (shell.endedAt ?? now) - shell.startedAt);
const taskElapsed = (task: Task, now: number) =>
  task.type === "agent" ? elapsed(task.agent, now) : shellElapsed(task.shell, now);
const agentStateLabel = (t: Translate, agent: Subagent) =>
  t(STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed);
const taskIcon = (task: Task) =>
  task.type === "shell" ? "terminal" : isWorkflow(task.agent) ? "agent.activity" : "agent.session";

/// A task's glyph: the harness mark for an agent (as the shared row's avatar), the workflow and
/// shell icons otherwise.
function TaskIcon({ task }: { task: Task }) {
  const harness = useContext(SubagentHarnessContext);
  if (task.type === "agent" && !isWorkflow(task.agent) && agentBrand(harness))
    return <AgentMark agent={harness} size={14} />;
  return <Icon name={taskIcon(task)} size={14} />;
}

/// The panel's tasks with its optimistic stops and removals applied.
function usePanelTasks(agents: Subagent[], shells: BackgroundShell[]) {
  const [stopped, setStopped] = useState<Record<string, number>>({});
  const [removed, setRemoved] = useState<ReadonlySet<string>>(new Set());
  const tasks: Task[] = [
    ...agents.map((agent): Task => {
      const at = stopped[agent.id];
      return {
        type: "agent",
        agent: at && agent.state === "running" ? { ...agent, state: "cancelled", endedAt: at } : agent,
      };
    }),
    ...shells.map((shell): Task => {
      const at = stopped[shell.id];
      return {
        type: "shell",
        shell: at && shell.state === "running" ? { ...shell, state: "stopped", endedAt: at } : shell,
      };
    }),
  ].filter((task) => !removed.has(taskId(task)));
  // Workflows, then agents, then shells; each oldest first.
  const rank = (task: Task) => (task.type === "shell" ? 2 : isWorkflow(task.agent) ? 0 : 1);
  const live = tasks.filter(isRunning).sort((a, b) => rank(a) - rank(b) || startedAt(a) - startedAt(b));
  const finished = tasks.filter((task) => !isRunning(task)).sort((a, b) => startedAt(b) - startedAt(a));
  return {
    live,
    finished,
    stop: (id: string) => setStopped((prev) => ({ ...prev, [id]: Date.now() })),
    remove: (ids: string[]) => setRemoved((prev) => new Set([...prev, ...ids])),
  };
}

export function BackgroundTasksPanel({
  layout,
  agents,
  shells,
  harness,
  finishedOpen = false,
  onOpen,
  onClose,
}: BackgroundTasksPanelProps) {
  const t = useT();
  const { live, finished, stop, remove } = usePanelTasks(agents, shells);
  const [open, setOpen] = useState(finishedOpen);
  const now = useNow(live.length > 0);
  const menu = (task: Task): ContextMenuItem[] => {
    const id = taskId(task);
    const items: ContextMenuItem[] = [];
    if (task.type === "agent" && onOpen)
      items.push({ id: "open", label: t("bgTasks.viewTranscript"), onSelect: () => onOpen(id) });
    if (task.type === "shell")
      items.push({
        id: "copy",
        label: t("bgTasks.copyCommand"),
        onSelect: () => void navigator.clipboard?.writeText(task.shell.command).catch(() => undefined),
      });
    if (isRunning(task))
      items.push({
        id: "stop",
        label: t("bgTasks.stop"),
        destructive: true,
        separatorBefore: true,
        onSelect: () => stop(id),
      });
    else items.push({ id: "remove", label: t("bgTasks.remove"), separatorBefore: true, onSelect: () => remove([id]) });
    return items;
  };
  const props: LayoutProps = { now, onOpen, onStop: stop, menu };
  const Body = LAYOUTS[layout];
  return (
    <SubagentHarnessContext.Provider value={harness}>
      <section className="bgtasks" data-layout={layout} aria-label={t("summary.backgroundTasks")}>
        <header className="bgtasks__header">
          <h2 className="bgtasks__title">{t("summary.backgroundTasks")}</h2>
          {live.length > 0 && (
            <span className="bgtasks__count">{t("summary.subagents.running", { n: live.length })}</span>
          )}
          <span className="bgtasks__spacer" />
          {finished.length > 0 && (
            <button type="button" className="bgtasks__text-button" onClick={() => remove(finished.map(taskId))}>
              {t("bgTasks.clearAll")}
            </button>
          )}
          {onClose && (
            <button
              type="button"
              className="bgtasks__icon-button"
              aria-label={t("bgTasks.close")}
              title={t("bgTasks.close")}
              onClick={onClose}
            >
              <Icon name="action.close" size={14} />
            </button>
          )}
        </header>
        <div className="bgtasks__scroll">
          {live.length === 0 && finished.length === 0 && <p className="bgtasks__empty">{t("bgTasks.empty")}</p>}
          <Body tasks={live} {...props} />
          {finished.length > 0 && (
            <>
              <button type="button" className="bgtasks__finished" aria-expanded={open} onClick={() => setOpen(!open)}>
                <span>{t("bgTasks.finished")}</span>
                <span className="bgtasks__finished-count">{finished.length}</span>
                <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
              </button>
              {open &&
                (layout === "cards" ? (
                  <CompactRows tasks={finished} {...props} />
                ) : (
                  <Body tasks={finished} {...props} />
                ))}
            </>
          )}
        </div>
      </section>
    </SubagentHarnessContext.Provider>
  );
}

type LayoutProps = {
  now: number;
  onOpen?: (id: string) => void;
  onStop: (id: string) => void;
  menu: (task: Task) => ContextMenuItem[];
};

const LAYOUTS: Record<BackgroundTasksLayout, (props: LayoutProps & { tasks: Task[] }) => ReactNode> = {
  list: DenseList,
  cards: Cards,
  grouped: Grouped,
  grouped2: GroupedTwoLine,
};

function StopButton({
  name,
  onStop,
  className,
  solid = false,
}: {
  name: string;
  onStop: () => void;
  className: string;
  /// The composer's filled stop square (C2) instead of the outlined one.
  solid?: boolean;
}) {
  const t = useT();
  return (
    <button
      type="button"
      className={className}
      aria-label={t("subagents.stop", { name })}
      title={t("subagents.stop", { name })}
      onClick={onStop}
    >
      <Icon name="action.stop" selected={solid} size={solid ? 14 : 12} />
    </button>
  );
}

/* ---------- (A) Dense list: the shared subagent row ---------- */

const edge = (index: number, count: number) =>
  count === 1 ? "only" : index === 0 ? "first" : index === count - 1 ? "last" : undefined;

function DenseList({ tasks, now, onOpen, onStop, menu }: LayoutProps & { tasks: Task[] }) {
  if (tasks.length === 0) return null;
  return (
    <SubagentPaneContext.Provider value={onOpen}>
      <SubagentStopContext.Provider value={onStop}>
        <div className="bgtasks__list">
          {tasks.map((task, index) => {
            const status = edge(index, tasks.length);
            return (
              <ContextMenu key={taskId(task)} items={menu(task)}>
                {task.type === "agent" ? (
                  <SubagentListRow row={agentRow(task.agent, status)} />
                ) : (
                  <ShellListRow shell={task.shell} edge={status} now={now} onStop={onStop} />
                )}
              </ContextMenu>
            );
          })}
        </div>
      </SubagentStopContext.Provider>
    </SubagentPaneContext.Provider>
  );
}

const agentRow = (agent: Subagent, status: string | undefined): AcpmuxRow => ({
  id: `bgtasks:${agent.id}`,
  version: 0,
  at: agent.startedAt,
  kind: "subagents",
  status,
  subagents: [agent],
});

/// A background shell in the shared row's shape: the command over its last line of output.
function ShellListRow({
  shell,
  edge: rowEdge,
  now,
  onStop,
}: {
  shell: BackgroundShell;
  edge: string | undefined;
  now: number;
  onStop: (id: string) => void;
}) {
  const t = useT();
  const live = shell.state === "running";
  const last = shell.output.at(-1);
  const line = live ? (last ?? t("bgTasks.noOutput")) : t(SHELL_STATE[shell.state]);
  const row = (
    <div className="cv-subagent bgtasks-shell-row" data-edge={rowEdge}>
      <span className="cv-subagent-avatar" data-state={shell.state === "stopped" ? "cancelled" : shell.state}>
        <Icon name="terminal" size={14} />
        <span className="cv-subagent-avatar__dot" aria-hidden="true" />
      </span>
      <span className="cv-subagent__text">
        <span className="cv-subagent__name bgtasks__mono">{shell.command}</span>
        <span className="cv-subagent__state" data-empty={live && !last ? "" : undefined}>
          {line}
        </span>
      </span>
      <span className="cv-subagent__time">{formatDuration(shellElapsed(shell, now))}</span>
    </div>
  );
  if (!live) return row;
  return (
    <div className="cv-subagent-stoppable">
      {row}
      <StopButton className="cv-subagent__stop" name={shell.command} onStop={() => onStop(shell.id)} />
    </div>
  );
}

/* ---------- (B) Cards, Claude desktop style ---------- */

function Cards({ tasks, now, onOpen, onStop, menu }: LayoutProps & { tasks: Task[] }) {
  const t = useT();
  const language = usePaneLanguage();
  if (tasks.length === 0) return null;
  return (
    <div className="bgtasks__cards">
      {tasks.map((task) => {
        const id = taskId(task);
        const name = task.type === "agent" ? task.agent.name : task.shell.command;
        return (
          <ContextMenu key={id} items={menu(task)}>
            <article className="bgtasks-card" data-type={task.type}>
              <div className="bgtasks-card__head">
                <span className="bgtasks-card__icon" data-state={isRunning(task) ? "running" : undefined}>
                  <TaskIcon task={task} />
                </span>
                <span className={task.type === "shell" ? "bgtasks-card__name bgtasks__mono" : "bgtasks-card__name"}>
                  {name}
                </span>
                {task.type === "agent" && task.agent.kind && (
                  <span className="bgtasks-card__kind">{task.agent.kind}</span>
                )}
                <span className="bgtasks__spacer" />
                <span className="bgtasks__time">{formatDuration(taskElapsed(task, now))}</span>
                {isRunning(task) && (
                  <StopButton className="bgtasks__icon-button" name={name} onStop={() => onStop(id)} />
                )}
              </div>
              {task.type === "agent" ? (
                <>
                  {task.agent.action && <div className="bgtasks-card__action">{task.agent.action}</div>}
                  {task.agent.agents && task.agent.agents.started > 0 && (
                    <div className="bgtasks__progress" aria-hidden="true">
                      <span style={{ width: `${(100 * task.agent.agents.done) / task.agent.agents.started}%` }} />
                    </div>
                  )}
                  <div className="bgtasks-card__foot">
                    <span className="bgtasks-card__meta">{subagentProgress(t, language, task.agent).join(" · ")}</span>
                    {onOpen && (
                      <button type="button" className="bgtasks__link" onClick={() => onOpen(id)}>
                        {t("bgTasks.viewTranscript")}
                      </button>
                    )}
                  </div>
                </>
              ) : (
                <ShellOutput shell={task.shell} />
              )}
            </article>
          </ContextMenu>
        );
      })}
    </div>
  );
}

function ShellOutput({ shell, inline = false }: { shell: BackgroundShell; inline?: boolean }) {
  const t = useT();
  const lines = shell.output.slice(-TAIL);
  if (lines.length === 0)
    return (
      <div className={inline ? "bgtasks-output bgtasks-output--inline" : "bgtasks-output"} data-empty="">
        {t("bgTasks.noOutput")}
      </div>
    );
  return <pre className={inline ? "bgtasks-output bgtasks-output--inline" : "bgtasks-output"}>{lines.join("\n")}</pre>;
}

/// Finished tasks under the cards: one 28px line each, not a card.
function CompactRows({ tasks, now, onOpen, menu }: LayoutProps & { tasks: Task[] }) {
  return (
    <ul className="bgtasks__rows">
      {tasks.map((task) => (
        <li key={taskId(task)}>
          <ContextMenu items={menu(task)}>
            <CompactRow task={task} now={now} onOpen={onOpen} />
          </ContextMenu>
        </li>
      ))}
    </ul>
  );
}

/* ---------- (C) Grouped by kind, live output inline ---------- */

const GROUPS: { key: StringKey; match: (task: Task) => boolean }[] = [
  { key: "bgTasks.group.workflows", match: (task) => task.type === "agent" && isWorkflow(task.agent) },
  { key: "bgTasks.group.agents", match: (task) => task.type === "agent" && !isWorkflow(task.agent) },
  { key: "bgTasks.group.shells", match: (task) => task.type === "shell" },
];

function Grouped({ tasks, now, onOpen, onStop, menu }: LayoutProps & { tasks: Task[] }) {
  const t = useT();
  if (tasks.length === 0) return null;
  // Finished tasks are already one short list: no group labels there.
  if (!tasks.some(isRunning))
    return <CompactRows tasks={tasks} now={now} onOpen={onOpen} onStop={onStop} menu={menu} />;
  return (
    <div className="bgtasks__groups">
      {GROUPS.map(({ key, match }) => {
        const members = tasks.filter(match);
        if (members.length === 0) return null;
        return (
          <section key={key} className="bgtasks-group" aria-label={t(key)}>
            <h3 className="bgtasks-group__label">
              {t(key)}
              <span className="bgtasks-group__count">{members.length}</span>
            </h3>
            <ul className="bgtasks__rows">
              {members.map((task) => (
                <li key={taskId(task)}>
                  <ContextMenu items={menu(task)}>
                    <CompactRow task={task} now={now} onOpen={onOpen} onStop={onStop} />
                    {task.type === "shell" && isRunning(task) && <ShellOutput shell={task.shell} inline />}
                  </ContextMenu>
                </li>
              ))}
            </ul>
          </section>
        );
      })}
    </div>
  );
}

/// One 28px line: icon, name, what it does now (or how it ended), its spend, time and stop.
function CompactRow({
  task,
  now,
  onOpen,
  onStop,
  solidStop = false,
}: {
  task: Task;
  now: number;
  onOpen?: (id: string) => void;
  onStop?: (id: string) => void;
  solidStop?: boolean;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const id = taskId(task);
  const live = isRunning(task);
  const name = task.type === "agent" ? task.agent.name : task.shell.command;
  const detail =
    task.type === "agent"
      ? live
        ? (task.agent.action ?? agentStateLabel(t, task.agent))
        : agentStateLabel(t, task.agent)
      : t(SHELL_STATE[task.shell.state]);
  const progress = task.type === "agent" && live ? subagentProgress(t, language, task.agent)[0] : undefined;
  const state = task.type === "agent" ? task.agent.state : task.shell.state;
  const content = (
    <>
      <span className="bgtasks-row__icon" data-state={state}>
        <TaskIcon task={task} />
      </span>
      <span className={task.type === "shell" ? "bgtasks-row__name bgtasks__mono" : "bgtasks-row__name"}>{name}</span>
      {!(task.type === "shell" && live) && <span className="bgtasks-row__detail">{detail}</span>}
      <span className="bgtasks__spacer" />
      {progress && <span className="bgtasks__time">{progress}</span>}
      <span className="bgtasks__time">{formatDuration(taskElapsed(task, now))}</span>
    </>
  );
  const workflow = task.type === "agent" && task.agent.agents && live ? task.agent.agents : undefined;
  const bar = workflow && workflow.started > 0 && (
    <span className="bgtasks__progress bgtasks__progress--row" aria-hidden="true">
      <span style={{ width: `${(100 * workflow.done) / workflow.started}%` }} />
    </span>
  );
  const line =
    task.type === "agent" && onOpen ? (
      <button
        type="button"
        className="bgtasks-row"
        title={task.agent.task ?? name}
        aria-label={t("subagents.open", { name })}
        onClick={() => onOpen(id)}
      >
        {content}
        {bar}
      </button>
    ) : (
      <div className="bgtasks-row" title={name}>
        {content}
        {bar}
      </div>
    );
  if (!live || !onStop) return line;
  return (
    <div className="bgtasks-row-stoppable">
      {line}
      <StopButton
        className={
          solidStop ? "bgtasks__icon-button bgtasks-row__stop bgtasks-stop" : "bgtasks__icon-button bgtasks-row__stop"
        }
        name={name}
        solid={solidStop}
        onStop={() => onStop(id)}
      />
    </div>
  );
}

/* ---------- (C2) Grouped, two-line agent rows ---------- */

function GroupedTwoLine({ tasks, now, onOpen, onStop, menu }: LayoutProps & { tasks: Task[] }) {
  const t = useT();
  if (tasks.length === 0) return null;
  if (!tasks.some(isRunning)) return <FinishedRows tasks={tasks} now={now} onOpen={onOpen} menu={menu} />;
  const groups = GROUPS.map((group) => ({ ...group, members: tasks.filter(group.match) })).filter(
    (group) => group.members.length > 0,
  );
  // One kind needs no label: the rows' icons already say what they are.
  const labelled = groups.length > 1;
  return (
    <div className="bgtasks__groups bgtasks-c2">
      {groups.map(({ key, members }) => (
        <section key={key} className="bgtasks-group" aria-label={t(key)}>
          {labelled && (
            <h3 className="bgtasks-c2__label">
              {t(key)}
              <span>{members.length}</span>
            </h3>
          )}
          <ul className="bgtasks__rows">
            {members.map((task) => (
              <li key={taskId(task)}>
                <ContextMenu items={menu(task)}>
                  {task.type === "agent" ? (
                    <AgentTwoLineRow agent={task.agent} now={now} onOpen={onOpen} onStop={onStop} />
                  ) : (
                    <>
                      <CompactRow task={task} now={now} onOpen={onOpen} onStop={onStop} solidStop />
                      {isRunning(task) && <ShellOutput shell={task.shell} inline />}
                    </>
                  )}
                </ContextMenu>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}

/// About 40px: icon, title, kind, time and stop over a muted line of what it does now, then its spend.
function AgentTwoLineRow({
  agent,
  now,
  onOpen,
  onStop,
}: {
  agent: Subagent;
  now: number;
  onOpen?: (id: string) => void;
  onStop?: (id: string) => void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const live = agent.state === "running";
  const task: Task = { type: "agent", agent };
  const action = live ? agent.action : agentStateLabel(t, agent);
  const spend = subagentProgress(t, language, agent).join(" · ");
  // A workflow's icon and agent count already say what it is: no kind chip, so the title keeps room.
  const kind = isWorkflow(agent) ? undefined : agent.kind;
  const workflow = live && agent.agents && agent.agents.started > 0 ? agent.agents : undefined;
  const content = (
    <>
      <span className="bgtasks-c2__line">
        <span className="bgtasks-row__icon" data-state={agent.state}>
          <TaskIcon task={task} />
        </span>
        <span className="bgtasks-c2__title">{agent.name}</span>
        {kind && <span className="bgtasks-card__kind bgtasks-c2__kind">{kind}</span>}
        <span className="bgtasks__spacer" />
        <span className="bgtasks__time">{formatDuration(elapsed(agent, now))}</span>
      </span>
      {(action || spend) && (
        <span className="bgtasks-c2__sub">
          {action && <span className="bgtasks-c2__action">{action}</span>}
          {action && spend && <span className="bgtasks-c2__sep">·</span>}
          {spend && <span className="bgtasks-c2__spend">{spend}</span>}
        </span>
      )}
      {workflow && (
        <span className="bgtasks__progress bgtasks__progress--row bgtasks-c2__progress" aria-hidden="true">
          <span style={{ width: `${(100 * workflow.done) / workflow.started}%` }} />
        </span>
      )}
    </>
  );
  const row = onOpen ? (
    <button
      type="button"
      className="bgtasks-row bgtasks-c2__row"
      title={agent.task ?? agent.name}
      aria-label={t("subagents.open", { name: agent.name })}
      onClick={() => onOpen(agent.id)}
    >
      {content}
    </button>
  ) : (
    <div className="bgtasks-row bgtasks-c2__row" title={agent.task ?? agent.name}>
      {content}
    </div>
  );
  if (!live || !onStop) return row;
  return (
    <div className="bgtasks-row-stoppable">
      {row}
      <StopButton
        className="bgtasks__icon-button bgtasks-stop bgtasks-c2__stop"
        name={agent.name}
        solid
        onStop={() => onStop(agent.id)}
      />
    </div>
  );
}

/// Finished under C2: one 28px line each (title · state · time), View transcript on hover.
function FinishedRows({ tasks, now, onOpen, menu }: Omit<LayoutProps, "onStop"> & { tasks: Task[] }) {
  const t = useT();
  return (
    <ul className="bgtasks__rows">
      {tasks.map((task) => {
        const id = taskId(task);
        const state = task.type === "agent" ? agentStateLabel(t, task.agent) : t(SHELL_STATE[task.shell.state]);
        return (
          <li key={id}>
            <ContextMenu items={menu(task)}>
              <div className="bgtasks-row bgtasks-c2__done">
                <span
                  className="bgtasks-row__icon"
                  data-state={task.type === "agent" ? task.agent.state : task.shell.state}
                >
                  <TaskIcon task={task} />
                </span>
                <span className="bgtasks-c2__done-text">
                  <span
                    className={task.type === "shell" ? "bgtasks-c2__done-name bgtasks__mono" : "bgtasks-c2__done-name"}
                  >
                    {task.type === "agent" ? task.agent.name : task.shell.command}
                  </span>
                  <span className="bgtasks-c2__done-meta">
                    {` · ${state} · ${formatDuration(taskElapsed(task, now))}`}
                  </span>
                </span>
                {task.type === "agent" && onOpen && (
                  <button type="button" className="bgtasks__link bgtasks-c2__view" onClick={() => onOpen(id)}>
                    {t("bgTasks.viewTranscript")}
                  </button>
                )}
              </div>
            </ContextMenu>
          </li>
        );
      })}
    </ul>
  );
}
