// The Background tasks panel (Leo, 2026-10-29: "i like these tasks i like the order that things split
// on the right i want that in cmux next"), Claude Desktop's panel of the same name in our colours,
// glass and type. It docks in the chat's right column, under the side panel when one is open
// (App.tsx, backgroundTasks.css), so it splits below what is already on the right.
//
// Top to bottom: the head (Background tasks, then Clear finished, Expand and Close); then a block per
// agent (backgroundTasks.ts): its name, which opens its transcript, its time and, while it runs, its
// stop button; under it the counts line, "39 tasks, 3 failed" with the failures in the danger colour,
// which opens its tasks: the running ones first, each with its time and its own stop button, then
// "N finished", folded, the latest first, each with how long it took.
//
// Opening an agent or a task drills into that agent's transcript in place (SubagentTranscript.tsx),
// with a back chevron (an agent opened from a transcript stacks, and Back steps out one at a time),
// and draws on the click: the transcript is the subagent's view acpmux already
// streamed into the chat's snapshot (`subagentViews`), so nothing waits on the daemon (Leo,
// 2026-10-29: "i also like the way it just loads in the subagent stuff instantly :("). The list
// stays mounted under it, so Back returns to it as it was: scrolled, folded and opened the same.
//
// A Claude workflow's agent is the one transcript that is not in the snapshot: it is read from the
// run's folder through acpmux (summary/useWorkflowTranscript.ts, the reader the app's workflow pane
// uses). Its drill-in draws on the click as well, with the transcript's Loading line until the first
// page lands, then the agent's rows; its progress refreshes it while it is open, and closing it
// disposes the reader. Workflow agents open only where the app reads workflows (Labs), as elsewhere.
//
// What runs turns the shared spinner, never a pulsing dot. Its one clock ticks each second only
// while something runs and the pane shows (SubagentGroup.tsx `useNow`), and stops with the panel.
import {
  createContext,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { formatDuration } from "../conversation/turns";
import { ChevronLeft, Close, Expand, Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { useNow } from "../subagents/SubagentGroup";
import type { WorkflowAgent } from "../summary/workflow";
import type { TranscriptRead } from "../summary/workflowTranscript";
import { useWorkflowTranscript } from "../summary/useWorkflowTranscript";
import {
  anyRunning,
  isLive,
  finishedGroupIds,
  type BackgroundGroup,
  type BackgroundTask,
  type StopTarget,
} from "./backgroundTasks";
import { NestedAgents, SubagentTranscript } from "./SubagentTranscript";
import "./backgroundTasks.css";

/// Whether this chat's subagents stop on their own (Claude Code's do; App.tsx `stopsSubagents`): a
/// subagent's row shows no stop button where it would do nothing (never a dead click).
const StopsAgents = createContext(true);

/// How a workflow agent's transcript is read (App.tsx `readWorkflowAgent`); unset, a workflow's
/// agents are listed but open nothing.
export type WorkflowReads = { sessionId?: string; chat: string; connection: string; read: TranscriptRead };
const Workflows = createContext<WorkflowReads | undefined>(undefined);

/// How many finished tasks a group lists before Show more, and how many more each press adds.
export const FINISHED_PAGE = 8;

/// The gallery's arms (BackgroundTasksPanel.gallery.tsx). `nested` is Claude Desktop's shape and
/// the one that ships; `flat` lists the running tasks under each agent with no counts line to open;
/// `compact` puts the counts on the agent's own line and opens the tasks from it.
export type PanelLook = "nested" | "flat" | "compact";

/// `agentId` is a subagent's id, or for a workflow's agent (`workflow`) its workflow pane id.
export type Drill = { agentId: string; rowId?: string; workflow?: boolean };

export function BackgroundTasksPanel({
  groups,
  views,
  look = "nested",
  expanded = false,
  initialDrill,
  stopsAgents = true,
  workflow,
  onStop,
  onClearFinished,
  onExpand,
  onClose,
  onOpenSession,
  onOpenCommand,
}: {
  groups: readonly BackgroundGroup[];
  /// The subagents' own rows (the snapshot's `subagentViews`), which a drill-in draws from.
  views?: Record<string, AcpmuxRow[]>;
  look?: PanelLook;
  /// The panel takes the whole right column (Expand); the side panel above it rests.
  expanded?: boolean;
  /// A gallery or a test opens on a transcript.
  initialDrill?: Drill;
  stopsAgents?: boolean;
  /// Reads a workflow agent's transcript; unset (Labs off), a workflow's agents open nothing.
  workflow?: WorkflowReads;
  onStop?(target: StopTarget): Promise<unknown>;
  onClearFinished(ids: string[]): void;
  onExpand(): void;
  onClose(): void;
  /// A started chat's row opens that chat; unset leaves it plain text.
  onOpenSession?(sessionId: string): void;
  /// A command's row opens its terminal; unset leaves it plain text.
  onOpenCommand?(task: BackgroundTask): void;
}) {
  const t = useT();
  const live = anyRunning(groups);
  const now = useNow(live);
  // The drill-ins, deepest last: an agent opened from another's transcript stacks on it, and Back
  // steps out one at a time, to the list last.
  const [stack, setStack] = useState<Drill[]>(() => (initialDrill ? [initialDrill] : []));
  // Workflows turned off (Labs) while a workflow agent's transcript shows: there is nothing to read
  // it with, so the panel steps back out of it rather than show a blank pane.
  if (!workflow && stack.some((entry) => entry.workflow)) setStack(stack.filter((entry) => !entry.workflow));
  const drill = stack.at(-1);
  const list = useRef<HTMLDivElement>(null);
  const listScroll = useRef(0);
  // The list stays mounted (hidden) under a transcript, so its open groups, folds and Show more
  // stay as they were; Back puts its scroll where it was before the paint, so it never jumps.
  useLayoutEffect(() => {
    if (!drill && list.current) list.current.scrollTop = listScroll.current;
  }, [drill]);
  const open = (next: Drill) => {
    if (!drill) listScroll.current = list.current?.scrollTop ?? 0;
    setStack((now) => [...now, next]);
  };
  const back = () => setStack((now) => now.slice(0, -1));
  const nested = {
    open: (agentId: string) => open({ agentId }),
    stop: (agentId: string, name: string) => (
      <StopSlot target={{ kind: "agent", id: agentId }} name={name} onStop={onStop} />
    ),
  };
  const finished = useMemo(() => finishedGroupIds(groups), [groups]);
  const drilled = drill && agentOf(groups, drill.agentId);
  return (
    <StopsAgents.Provider value={stopsAgents}>
      <Workflows.Provider value={workflow}>
        <PanelFrame
          title={drill ? (drilled?.name ?? drill.agentId) : t("backgroundTasks.title")}
          back={drill ? back : undefined}
          backLabel={t("backgroundTasks.back")}
          clear={!drill && finished.length > 0 ? () => onClearFinished(finished) : undefined}
          expanded={expanded}
          onExpand={onExpand}
          onClose={onClose}
        >
          <div ref={list} className="acpmux-bg__list" data-look={look} hidden={drill !== undefined}>
            {groups.length === 0 ? (
              <p className="acpmux-bg__empty">{t("backgroundTasks.empty")}</p>
            ) : (
              groups.map((group, index) => (
                <GroupBlock
                  key={group.id}
                  group={group}
                  look={look}
                  now={now}
                  startsOpen={index === 0 && isLive(group)}
                  onDrill={open}
                  onStop={onStop}
                  onOpenSession={onOpenSession}
                  onOpenCommand={onOpenCommand}
                />
              ))
            )}
          </div>
          {drill?.workflow && workflow && (
            // Workflow transcripts list no nested agents today (summary/workflowTranscript.ts reads
            // them with no subagents); should one, it opens and stops as anywhere else in the panel.
            <NestedAgents.Provider value={nested}>
              <WorkflowAgentTranscript
                key={`${stack.length}:${drill.agentId}`}
                pane={drill.agentId}
                agent={drilled?.workflow}
                running={drilled?.state === "running"}
                reads={workflow}
              />
            </NestedAgents.Provider>
          )}
          {drill && !drill.workflow && (
            <NestedAgents.Provider value={nested}>
              <SubagentTranscript
                key={`${stack.length}:${drill.agentId}`}
                rows={views?.[drill.agentId] ?? []}
                running={drilled?.state === "running"}
                anchor={drill.rowId}
              />
            </NestedAgents.Provider>
          )}
        </PanelFrame>
      </Workflows.Provider>
    </StopsAgents.Provider>
  );
}

/// The group a subagent is, or the one it is a task of.
function agentOf(groups: readonly BackgroundGroup[], agentId: string) {
  for (const group of groups) {
    if (group.agentId === agentId) return { name: group.name, state: group.state };
    for (const task of [...group.running, ...group.finished]) {
      if (task.kind === "agent" && task.agentId === agentId) return { name: task.title, state: task.state };
      if (task.workflow?.pane === agentId)
        return { name: task.title, state: task.state, workflow: task.workflow.agent };
    }
  }
  return undefined;
}

/// A workflow agent's transcript, read through acpmux as the app's workflow pane reads it. Its rows
/// draw in the same transcript as a subagent's; the Loading line shows from the click until the
/// first page lands, so the pane is never blank.
function WorkflowAgentTranscript({
  pane,
  agent,
  running,
  reads,
}: {
  pane: string;
  agent?: WorkflowAgent;
  running: boolean;
  reads: WorkflowReads;
}) {
  const transcript = useWorkflowTranscript(
    pane,
    reads.sessionId,
    true,
    agent,
    reads.chat,
    reads.read,
    reads.connection,
  );
  // The first row is the "Subagent of" pill the app's pane leads with; the panel's head names it. The
  // hook's notice row (Loading, or why the history is short) is a line of its own above the rows, so
  // the window is taken from the agent's rows when they arrive, never from the notice.
  const rows = useMemo(
    () => (transcript.rows?.slice(1) ?? []).filter((row) => row.kind !== "notice"),
    [transcript.rows],
  );
  const notice = transcript.rows?.find((row) => row.kind === "notice")?.text;
  // Older history, a page at a time, from the transcript's top (the hook's loader changes each render).
  const loader = useRef(transcript.loadOlder);
  loader.current = transcript.loadOlder;
  const loadOlder = useCallback(() => loader.current(), []);
  return (
    <SubagentTranscript
      rows={rows}
      running={running}
      notice={notice}
      onLoadOlder={transcript.canLoadOlder ? loadOlder : undefined}
    />
  );
}

function PanelFrame({
  title,
  back,
  backLabel,
  clear,
  expanded,
  onExpand,
  onClose,
  children,
}: {
  title: string;
  back?: () => void;
  backLabel?: string;
  clear?: () => void;
  expanded: boolean;
  onExpand(): void;
  onClose(): void;
  children: ReactNode;
}) {
  const t = useT();
  const expandLabel = t(expanded ? "backgroundTasks.collapse" : "backgroundTasks.expand");
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape steps back or closes from anywhere inside.
    <section
      className="acpmux-bg"
      aria-label={t("backgroundTasks.title")}
      data-expanded={expanded || undefined}
      // ui-allow: Escape steps back out of a transcript, else closes the panel
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        event.preventDefault();
        if (back) back();
        else onClose();
      }}
    >
      <header className="acpmux-bg__head">
        {back && (
          <button type="button" className="cv-iconbtn cv-iconbtn--compact" aria-label={backLabel} onClick={back}>
            <ChevronLeft size={14} />
          </button>
        )}
        <h2 className="acpmux-bg__title">{title}</h2>
        <span className="acpmux-bg__tools">
          {clear && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("backgroundTasks.clearFinished")}
              title={t("backgroundTasks.clearFinished")}
              onClick={clear}
            >
              <Icon name="action.delete" size={14} />
            </button>
          )}
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={expandLabel}
            title={expandLabel}
            aria-pressed={expanded}
            onClick={onExpand}
          >
            <Expand size={14} />
          </button>
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={t("backgroundTasks.close")}
            title={t("backgroundTasks.close")}
            onClick={onClose}
          >
            <Close size={14} />
          </button>
        </span>
      </header>
      {children}
    </section>
  );
}

/// Elapsed while it runs; once ended, its duration, or nothing when its end time is unknown (a
/// command known only from the transcript), never a time that keeps counting.
const time = (from: number | undefined, to: number | undefined, now: number, running: boolean) =>
  from === undefined || (!running && to === undefined)
    ? undefined
    : formatDuration(Math.max(0, (running ? now : to!) - from));

function GroupBlock({
  group,
  look,
  now,
  startsOpen,
  onDrill,
  onStop,
  onOpenSession,
  onOpenCommand,
}: {
  group: BackgroundGroup;
  look: PanelLook;
  now: number;
  startsOpen: boolean;
  onDrill(drill: Drill): void;
  onStop?(target: StopTarget): Promise<unknown>;
  onOpenSession?(sessionId: string): void;
  onOpenCommand?(task: BackgroundTask): void;
}) {
  const [open, setOpen] = useState(startsOpen || look === "flat");
  const agentId = group.agentId;
  const sessionId = group.sessionId;
  const opens = agentId
    ? () => onDrill({ agentId })
    : sessionId && onOpenSession
      ? () => onOpenSession(sessionId)
      : undefined;
  const counts = <Counts total={group.total} failed={group.failed} />;
  // A group whose own agent ended still runs while any of its tasks (a nested agent) does.
  const live = isLive(group);
  return (
    <div className="acpmux-bg__group" data-state={live ? "running" : group.state} data-group={group.id}>
      <div className="acpmux-bg__agent">
        <button type="button" className="acpmux-bg__name" disabled={!opens} onClick={opens}>
          {live && <Spinner size={12} loading />}
          <span className="acpmux-bg__label">{group.name}</span>
          {opens && (
            <span className="acpmux-bg__chevron" aria-hidden="true">
              <Icon name="disclosure.collapsed" size={12} row />
            </span>
          )}
        </button>
        {look === "compact" && group.total > 0 && (
          <button type="button" className="acpmux-bg__counts" aria-expanded={open} onClick={() => setOpen(!open)}>
            {counts}
          </button>
        )}
        <span className="acpmux-bg__time">{time(group.startedAt, group.endedAt, now, live)}</span>
        <StopSlot target={group.stop} name={group.name} onStop={onStop} />
      </div>
      {look === "nested" && group.total > 0 && (
        <button type="button" className="acpmux-bg__fold" aria-expanded={open} onClick={() => setOpen(!open)}>
          <Disclosure open={open} />
          {counts}
        </button>
      )}
      {open && group.total > 0 && (
        <TaskList
          group={group}
          now={now}
          nested={look !== "flat"}
          onDrill={onDrill}
          onStop={onStop}
          onOpenCommand={onOpenCommand}
        />
      )}
    </div>
  );
}

/// "39 tasks, 3 failed", the failures in the danger colour.
function Counts({ total, failed }: { total: number; failed: number }) {
  const t = useT();
  const tasks = t(total === 1 ? "backgroundTasks.tasks.one" : "backgroundTasks.tasks.other", { n: total });
  if (failed === 0) return <span>{tasks}</span>;
  return (
    <span>
      {t("backgroundTasks.countsJoin", { tasks })}
      <span className="acpmux-bg__failed">{t("backgroundTasks.failed", { n: failed })}</span>
    </span>
  );
}

const Disclosure = ({ open }: { open: boolean }) => (
  <span className="acpmux-bg__disclosure" aria-hidden="true">
    <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />
  </span>
);

function TaskList({
  group,
  now,
  nested,
  onDrill,
  onStop,
  onOpenCommand,
}: {
  group: BackgroundGroup;
  now: number;
  nested: boolean;
  onDrill(drill: Drill): void;
  onStop?(target: StopTarget): Promise<unknown>;
  onOpenCommand?(task: BackgroundTask): void;
}) {
  const t = useT();
  const [finishedOpen, setFinishedOpen] = useState(!nested);
  const [shown, setShown] = useState(FINISHED_PAGE);
  const row = (task: BackgroundTask) => (
    <TaskRow key={task.id} task={task} now={now} onDrill={onDrill} onStop={onStop} onOpenCommand={onOpenCommand} />
  );
  const finished = group.finished;
  return (
    <div className="acpmux-bg__tasks">
      {group.running.map(row)}
      {finished.length > 0 && nested && (
        <button
          type="button"
          className="acpmux-bg__fold acpmux-bg__fold--finished"
          aria-expanded={finishedOpen}
          onClick={() => setFinishedOpen(!finishedOpen)}
        >
          <Disclosure open={finishedOpen} />
          <span>{t("backgroundTasks.finished", { n: finished.length })}</span>
        </button>
      )}
      {finishedOpen && (
        <div className={nested ? "acpmux-bg__finished" : undefined}>
          {finished.slice(0, shown).map(row)}
          {finished.length > shown && (
            <button type="button" className="acpmux-bg__more" onClick={() => setShown(shown + FINISHED_PAGE * 3)}>
              {t("backgroundTasks.showMore")}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function TaskRow({
  task,
  now,
  onDrill,
  onStop,
  onOpenCommand,
}: {
  task: BackgroundTask;
  now: number;
  onDrill(drill: Drill): void;
  onStop?(target: StopTarget): Promise<unknown>;
  onOpenCommand?(task: BackgroundTask): void;
}) {
  const agentId = task.agentId;
  const pane = useContext(Workflows) ? task.workflow?.pane : undefined;
  const opens = agentId
    ? () => onDrill({ agentId, rowId: task.kind === "agent" ? undefined : task.rowId })
    : pane
      ? () => onDrill({ agentId: pane, workflow: true })
      : task.kind === "command" && onOpenCommand
        ? () => onOpenCommand(task)
        : undefined;
  return (
    <div className="acpmux-bg__task" data-state={task.state}>
      <button type="button" className="acpmux-bg__task-open" disabled={!opens} onClick={opens}>
        {task.state === "running" ? (
          <Spinner size={12} loading />
        ) : (
          <span className="acpmux-bg__disclosure" aria-hidden="true">
            <Icon name="disclosure.collapsed" size={12} row />
          </span>
        )}
        <span className="acpmux-bg__label">{task.title}</span>
      </button>
      <span className="acpmux-bg__time">{time(task.startedAt, task.endedAt, now, task.state === "running")}</span>
      <StopSlot target={task.stop} name={task.title} onStop={onStop} />
    </div>
  );
}

/// A running row's own stop button; an empty slot keeps the times in one column.
function StopSlot({
  target,
  name,
  onStop,
}: {
  target?: StopTarget;
  name: string;
  onStop?(target: StopTarget): Promise<unknown>;
}) {
  const t = useT();
  const [state, setState] = useState<"idle" | "stopping" | "failed">("idle");
  const stopsAgents = useContext(StopsAgents);
  // Its target ended: a later running period of the same agent or command starts with a live button.
  if (!target && state !== "idle") setState("idle");
  if (!target || !onStop || (target.kind === "agent" && !stopsAgents))
    return <span className="acpmux-bg__stop-slot" aria-hidden="true" />;
  const label = t(state === "failed" ? "backgroundTasks.stopFailed" : "backgroundTasks.stop", { name });
  return (
    <span className="acpmux-bg__stop-slot">
      <button
        type="button"
        className="acpmux-bg__stop"
        data-state={state}
        disabled={state === "stopping"}
        aria-label={label}
        title={label}
        onClick={() => {
          setState("stopping");
          onStop(target).catch(() => setState("failed"));
        }}
      >
        <Icon name="action.stop" size={12} />
      </button>
    </span>
  );
}
