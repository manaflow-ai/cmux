// The Tasks page: one of three layouts (user setting `tasks.layout`: list, board, inbox) over one
// store. A change the page makes shows at once (the store's pending intents) and stays until the
// owner's echo confirms it, so nothing jumps back; changes made elsewhere (the CLI, an agent) arrive
// as owner events and never move the selection or the scroll (the origin rule).
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type DragEvent,
  createContext,
  memo,
  useContext,
  type ReactNode,
} from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { Menu, MenuButton, MenuCheckboxItem, MenuGroup, MenuPopup, MenuSeparator } from "../../ui/Menu";
import { SplitEdge } from "../../ui/SplitEdge";
import { VirtualList } from "../../ui/VirtualList";
import { ConnectionChip } from "../../ui/ConnectionChip";
import { useConnectionQuiet } from "../../ui/lasting";
import type { Strings } from "../shared/i18n";
import {
  agentName,
  assigneeChoices,
  firstInboxTask,
  inboxGroups,
  isCurrentChoice,
  sessionFor,
  shortName,
  stableId,
  statusGroups,
  type AssigneeChoice,
  type InboxGroupId,
  type IntentKind,
  type Mirror,
  intentTask,
  sessionsByTask,
  type Intent,
} from "./model";
import { AssigneeBadge, AttentionDot, LabelChips, LabelDots, PriorityMark, Progress, StatusMark, ansi } from "./Glyphs";
import type { TasksStore, TasksSnapshot } from "./store";
import type { Label, Layout, Session, Status, Task, Principal } from "./types";

/** The command that starts the local owner (shown when none answers). */
export const SERVE_COMMAND = "cmux task serve";

const ROW_HEIGHT = 28;
const HEADER_HEIGHT = 32;

export interface TasksPageProps {
  store: TasksStore;
  strings: Strings;
  layout: Layout;
  /** Writes the pasteboard (Copy Command). */
  copy?: (text: string) => void;
}

export function TasksPage({ store, strings, layout, copy }: TasksPageProps) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const t = strings.t;
  // An owner that does not answer is said only once that lasts (ui/lasting.ts): a launch or a daemon
  // restart leaves it unreachable for a few seconds, and the board stays as it was meanwhile. One that
  // never answered names the command that starts it at once: that is the person's to do.
  const unreachableLasting = useConnectionQuiet(state.connection === "unreachable");
  if (!state.everConnected && state.connection === "unreachable") {
    return (
      <main className="tasks-page">
        <OwnerNotRunning strings={strings} copy={copy} />
      </main>
    );
  }
  return (
    <main className="tasks-page" data-layout={layout} aria-busy={state.connection === "connecting"}>
      {/* A corner mark, out of flow (ui/ConnectionChip.tsx): the list under it never moves. */}
      {unreachableLasting ? <ConnectionChip text={t("owner.lost")} /> : null}
      {state.scope === "mine" ? (
        <div className="tasks-scope-bar">
          <Icon name="account" size={14} />
          <span>{t("inbox.mine")}</span>
          <button
            type="button"
            className="tasks-link-button"
            onClick={() => {
              store.setScope("all");
              // Keep the route in step (no hashchange), so the host's next My Tasks changes it again.
              if (typeof history !== "undefined") history.replaceState(null, "", "#/all");
            }}
          >
            {t("scope.showAll")}
          </button>
        </div>
      ) : null}
      <NewTaskField store={store} strings={strings} request={state.newTaskRequest} />
      {state.reject ? (
        <div className="tasks-reject" role="alert">
          <button type="button" className="tasks-reject-text" onClick={() => store.clearReject()}>
            {state.reject}
          </button>
        </div>
      ) : null}
      <UnsentStrip store={store} state={state} strings={strings} />
      {layout === "list" ? <ListLayout store={store} state={state} strings={strings} /> : null}
      {layout === "board" ? <BoardLayout store={store} state={state} strings={strings} /> : null}
      {layout === "inbox" ? <InboxLayout store={store} state={state} strings={strings} /> : null}
    </main>
  );
}

function OwnerNotRunning({ strings, copy }: { strings: Strings; copy?: (text: string) => void }) {
  return (
    <div className="tasks-owner-missing">
      <Icon name="task.status.todo" size={28} />
      <h1>{strings.t("owner.notRunning.title")}</h1>
      <p>{strings.t("owner.notRunning.hint")}</p>
      <div className="tasks-command">
        <code>{SERVE_COMMAND}</code>
        {copy ? (
          <button
            type="button"
            className="tasks-icon-button"
            aria-label={strings.t("owner.copyCommand")}
            title={strings.t("owner.copyCommand")}
            onClick={() => copy(SERVE_COMMAND)}
          >
            <Icon name="action.copy" size={12} />
          </button>
        ) : null}
      </div>
    </div>
  );
}

/** Return sends `create`; the field clears once the owner has the task, so a create whose outcome
 * is unknown (the link broke, the call timed out) keeps its text, with Retry (the same key; retry-prompt-ok: a write) and
 * Discard. Escape clears it (and gives up an unsent create). It takes focus only on a click or a
 * user-run New Task (`request` changes). */
function NewTaskField({ store, strings, request }: { store: TasksStore; strings: Strings; request: number }) {
  const input = useRef<HTMLInputElement | null>(null);
  const [title, setTitle] = useState("");
  const [sent, setSent] = useState<string | undefined>();
  const outcome = sent ? store.createOutcome(sent) : undefined;
  useEffect(() => {
    if (store.takeNewTaskRequest()) input.current?.focus();
  }, [request, store]);
  const settled = outcome?.state === "done" || outcome?.state === "refused" ? outcome.state : undefined;
  useEffect(() => {
    if (!settled) return;
    // Done: the next task starts empty. Refused: the text stays for the person to fix.
    if (settled === "done") setTitle("");
    setSent(undefined);
  }, [settled]);
  const unsentKey = outcome?.state === "unsent" ? outcome.key : undefined;
  const busy = outcome?.state === "sending" || unsentKey !== undefined;
  return (
    <label className={`tasks-new${unsentKey ? " unsent" : ""}`}>
      <Icon name="action.add" size={14} />
      <input
        ref={input}
        className="tasks-new-input"
        value={title}
        readOnly={busy}
        placeholder={strings.t("create.placeholder")}
        aria-label={strings.t("create.placeholder")}
        onChange={(event) => setTitle(event.target.value)}
        onKeyDown={(event) => {
          if (event.nativeEvent.isComposing) return;
          if (event.key === "Enter") {
            event.preventDefault();
            if (unsentKey) store.retry(unsentKey);
            else if (!busy) setSent(store.createTask(title));
          } else if (event.key === "Escape") {
            if (unsentKey) store.discard(unsentKey);
            setSent(undefined);
            setTitle("");
            input.current?.blur();
          }
        }}
      />
      {unsentKey ? (
        <UnsentActions
          strings={strings}
          onRetry={() => store.retry(unsentKey)}
          onDiscard={() => {
            store.discard(unsentKey);
            setSent(undefined);
          }}
        />
      ) : null}
    </label>
  );
}

/** "Not sent" with Retry and Discard: a change whose outcome is unknown, never resent on its own.
 * retry-prompt-ok: a resend writes the person's change (it may already have landed), so it is theirs. */
function UnsentActions({
  strings,
  onRetry,
  onDiscard,
}: {
  strings: Strings;
  onRetry: () => void;
  onDiscard: () => void;
}) {
  return (
    <span className="tasks-unsent">
      <span className="tasks-unsent-label">{strings.t("change.unsent")}</span>
      {/* retry-prompt-ok: resends the person's task change */}
      <button type="button" className="tasks-link-button" onClick={onRetry}>
        {strings.t("change.retry")}
      </button>
      <button type="button" className="tasks-link-button" onClick={onDiscard}>
        {strings.t("change.discard")}
      </button>
    </span>
  );
}

/** What an unsent change was: its task's key and the action, in the person's words. */
function unsentLabel(state: TasksSnapshot, strings: Strings, kind: IntentKind): { key: string; action: string } {
  if (kind.type === "create") return { key: "", action: strings.format("change.action.create", kind.title) };
  const key = state.mirror.tasks.get(kind.task)?.key ?? "";
  switch (kind.type) {
    case "setStatus": {
      const status = state.mirror.statuses.find((candidate) => candidate.id === kind.status);
      return { key, action: strings.format("change.action.status", status?.name ?? kind.status) };
    }
    case "archive":
      return { key, action: strings.t("change.action.archive") };
    case "assign":
      return {
        key,
        action: kind.person
          ? strings.format("change.action.assign", shortName(kind.person))
          : strings.t("change.action.unassign"),
      };
    case "delegate":
      return { key, action: strings.format("change.action.delegate", agentName(kind.harness)) };
    case "move":
      return { key, action: strings.t("change.action.move") };
  }
}

/** Every change whose outcome is unknown, in every layout and scope, with Retry and Discard: a row
 * can be out of view (another scope, a collapsed list), so the row's own marker is not enough. */
export function UnsentStrip({ store, state, strings }: LayoutProps) {
  const unsent = state.pending.filter((intent) => intent.unsent);
  if (!unsent.length) return null;
  return (
    <section className="tasks-unsent-strip" aria-label={strings.t("change.strip.title")}>
      <span className="tasks-unsent-strip-title">{strings.t("change.strip.title")}</span>
      <ul>
        {unsent.map((intent) => {
          const { key, action } = unsentLabel(state, strings, intent.kind);
          return (
            <li key={intent.key} className="tasks-unsent-item">
              {key ? <span className="tasks-key">{key}</span> : null}
              <span className="tasks-unsent-action">{action}</span>
              <span className="tasks-spacer" />
              {/* retry-prompt-ok: resends the person's task change */}
              <button type="button" className="tasks-link-button" onClick={() => store.retry(intent.key)}>
                {strings.t("change.retry")}
              </button>
              <button type="button" className="tasks-link-button" onClick={() => store.discard(intent.key)}>
                {strings.t("change.discard")}
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

/** A row's or card's unsent change, if any, as its Retry and Discard. */
function RowUnsent({ store, strings, intent }: { store: TasksStore; strings: Strings; intent: Intent | undefined }) {
  if (!intent) return null;
  return (
    <UnsentActions
      strings={strings}
      onRetry={() => store.retry(intent.key)}
      onDiscard={() => store.discard(intent.key)}
    />
  );
}

interface LayoutProps {
  store: TasksStore;
  state: TasksSnapshot;
  strings: Strings;
}

function labelsOf(labels: ReadonlyMap<string, Label>, task: Task): Label[] {
  return (task.labels ?? []).flatMap((id) => {
    const label = labels.get(id);
    return label ? [label] : [];
  });
}

const NO_LABELS: readonly Label[] = Object.freeze([]);
const rowLabels = new WeakMap<Task, readonly Label[]>();

/** A row's labels: the same array while the task and each of its label objects hold. A label event
 * replaces the label map but keeps the objects of the labels it did not change, so a row (a memo
 * boundary) redraws only when a label it wears changes, not on every label event. Costs the row's
 * own few labels; the cache is keyed by the task object and lets go of it with the task. */
function labelsFor(labels: ReadonlyMap<string, Label>, task: Task): readonly Label[] {
  const next = labelsOf(labels, task);
  if (!next.length) return NO_LABELS;
  const kept = rowLabels.get(task);
  if (kept && kept.length === next.length && kept.every((label, index) => label === next[index])) return kept;
  rowLabels.set(task, next);
  return next;
}

/** The workflow's few statuses, not the tasks. */
function statusOf(statuses: readonly Status[], task: Task): Status | undefined {
  return statuses.find((status) => status.id === task.status);
}

/** Right-click on a task: its status choices, then the Assignee choices. */
function useTaskMenu(
  store: TasksStore,
  statuses: readonly Status[],
  entries: readonly AssigneeEntry[],
  me: Principal | undefined,
  task: Task,
): ContextMenuItem[] {
  return useMemo(() => {
    const items: ContextMenuItem[] = statuses.map((status) => ({
      id: `status:${status.id}`,
      label: status.name,
      disabled: status.id === task.status,
      onSelect: () => store.setStatus(task.id, status.id),
    }));
    for (const [index, entry] of entries.entries()) {
      items.push({
        id: `assignee:${entry.id}`,
        label: entry.label,
        checked: isCurrentChoice({ me }, task, entry.choice),
        separatorBefore: index === 0,
        onSelect: () => void store.choose(task.id, entry.choice),
      });
    }
    return items;
  }, [store, statuses, entries, me, task]);
}

interface AssigneeEntry {
  id: string;
  label: string;
  group: "people" | "agents" | "nobody";
  choice: AssigneeChoice;
}

/** People, then agents, then Unassigned (decision T3). */
function assigneeEntries(mirror: Mirror, tasks: readonly Task[], strings: Strings): AssigneeEntry[] {
  const choices = assigneeChoices(mirror, tasks);
  const me = stableId(mirror.me);
  return [
    ...choices.people.map((id): AssigneeEntry => ({
      id: `person:${id}`,
      label: id === me ? strings.t("assignee.me") : shortName(id),
      group: "people",
      choice: { type: "person", id },
    })),
    ...choices.agents.map((harness): AssigneeEntry => ({
      id: `agent:${harness}`,
      label: agentName(harness),
      group: "agents",
      choice: { type: "agent", harness },
    })),
    { id: "nobody", label: strings.t("detail.unassigned"), group: "nobody", choice: { type: "nobody" } },
  ];
}

/** The Assignee entries, read once per change of the tasks (not once per row), kept as the same
 * array while the people and agents stay the same: every row's menu takes it, so a new array would
 * re-render every row on any task change. */
function useAssigneeEntries(mirror: Mirror, tasks: readonly Task[], strings: Strings): readonly AssigneeEntry[] {
  const next = useMemo(() => assigneeEntries(mirror, tasks, strings), [mirror, tasks, strings]);
  const [kept, setKept] = useState(next);
  const same =
    kept === next ||
    (kept.length === next.length &&
      kept.every((entry, index) => entry.id === next[index]!.id && entry.label === next[index]!.label));
  if (!same) setKept(next);
  return same ? kept : next;
}

/** What every row of a layout reads besides its own task. Each keeps its identity across events
 * that change no row (an owner event on another task, a selection elsewhere), so a row, a memo
 * boundary, re-renders only when its own task, selection or pending mark changes. */
interface RowShared {
  store: TasksStore;
  strings: Strings;
}

/** What every task's right-click menu lists: all statuses and assignees. It reaches the menus
 * through context, not the rows' props, so a status or assignee change redraws the mounted menus
 * (each lists them) without re-rendering the rows around them. */
interface MenuSource {
  store: TasksStore;
  statuses: readonly Status[];
  entries: readonly AssigneeEntry[];
  me: Principal | undefined;
}

const MenuSourceContext = createContext<MenuSource | null>(null);

/** A task's right-click menu around its row's button. */
function TaskMenu({ task, children }: { task: Task; children: ReactNode }) {
  const source = useContext(MenuSourceContext)!;
  const items = useTaskMenu(source.store, source.statuses, source.entries, source.me, task);
  return <ContextMenu items={items}>{children}</ContextMenu>;
}

/** Which tasks have a change in flight, and each one's unsent change: built once per change of the
 * pending intents, so a row reads its own by id instead of scanning them. */
interface PendingMarks {
  pending: ReadonlySet<string>;
  unsent: ReadonlyMap<string, Intent>;
}

function pendingMarks(intents: readonly Intent[]): PendingMarks {
  const pending = new Set<string>();
  const unsent = new Map<string, Intent>();
  for (const intent of intents) {
    const task = intentTask(intent.kind);
    pending.add(task);
    if (intent.unsent && !unsent.has(task)) unsent.set(task, intent);
  }
  return { pending, unsent };
}

function useRows({ store, state, strings }: LayoutProps): {
  shared: RowShared;
  marks: PendingMarks;
  menu: MenuSource;
  statusById: ReadonlyMap<string, Status>;
} {
  const entries = useAssigneeEntries(state.mirror, state.tasks, strings);
  const marks = useMemo(() => pendingMarks(state.pending), [state.pending]);
  const { statuses, me } = state.mirror;
  const menu = useMemo(() => ({ store, statuses, entries, me }), [store, statuses, entries, me]);
  // A status event keeps the objects of the statuses it did not change: a row's own one holds.
  const statusById = useMemo(() => new Map(statuses.map((status) => [status.id, status])), [statuses]);
  const shared: RowShared = { store, strings };
  return { shared, marks, menu, statusById };
}

interface TaskRowProps extends RowShared {
  task: Task;
  /** The task's labels (`labelsFor`). */
  labels: readonly Label[];
  /** The task's status, when the row shows it. */
  status?: Status;
  selected: boolean;
  pending: boolean;
  unsent: Intent | undefined;
  showStatus: boolean;
  style?: CSSProperties;
}

const TaskRow = memo(function TaskRow({
  store,
  strings,
  labels,
  task,
  status,
  selected,
  pending,
  unsent,
  showStatus,
  style,
}: TaskRowProps) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
    <div role="listitem" style={style} className="tasks-row-slot">
      <TaskMenu task={task}>
        <button
          type="button"
          data-focus-ring="row"
          aria-current={selected || undefined}
          className={`tasks-row${selected ? " selected" : ""}${pending ? " pending" : ""}`}
          data-task={task.id}
          onClick={() => store.select(task.id)}
        >
          <PriorityMark priority={task.priority} />
          <span className="tasks-key">{task.key}</span>
          {showStatus && status ? (
            <StatusMark category={status.category} color={status.color} title={status.name} />
          ) : null}
          <span className="tasks-title">{task.title}</span>
          <AttentionDot attention={task.attention} strings={strings} />
          <span className="tasks-spacer" />
          <LabelDots labels={labels} />
          <AssigneeBadge assignee={task.assignee} delegate={task.delegate} strings={strings} />
        </button>
      </TaskMenu>
      <RowUnsent store={store} strings={strings} intent={unsent} />
    </div>
  );
});

const StatusHeader = memo(function StatusHeader({
  status,
  count,
  style,
}: {
  status: Status;
  count: number;
  style?: CSSProperties;
}) {
  return (
    <div className="tasks-group-header" style={style} role="presentation">
      <StatusMark category={status.category} color={status.color} />
      <span className="tasks-group-title">{status.name}</span>
      <span className="tasks-count">{count}</span>
    </div>
  );
});

type ListRow = { kind: "status"; status: Status; count: number } | { kind: "task"; task: Task };

/** Variant `list`: dense rows grouped by status, in workflow order (virtualized). */
function ListLayout({ store, state, strings }: LayoutProps) {
  const rows = useMemo(() => {
    const out: ListRow[] = [];
    for (const group of statusGroups(state.mirror.statuses, state.shown)) {
      if (!group.tasks.length) continue;
      out.push({ kind: "status", status: group.status, count: group.tasks.length });
      for (const task of group.tasks) out.push({ kind: "task", task });
    }
    return out;
  }, [state.mirror.statuses, state.shown]);
  const { shared, marks, menu } = useRows({ store, state, strings });
  if (!rows.length) return <p className="tasks-empty">{strings.t("pane.empty")}</p>;
  return (
    <MenuSourceContext value={menu}>
      <VirtualList
        className="tasks-list"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList's role prop, its scroller is a div
        role="list"
        label={strings.t("pane.title")}
        count={rows.length}
        estimateSize={(index) => (rows[index]!.kind === "status" ? HEADER_HEIGHT : ROW_HEIGHT)}
        renderRow={(index, style) => {
          const row = rows[index]!;
          return row.kind === "status" ? (
            <StatusHeader key={`s:${row.status.id}`} status={row.status} count={row.count} style={style} />
          ) : (
            <TaskRow
              key={row.task.id}
              {...shared}
              task={row.task}
              labels={labelsFor(state.mirror.labels, row.task)}
              selected={state.selection === row.task.id}
              pending={marks.pending.has(row.task.id)}
              unsent={marks.unsent.get(row.task.id)}
              showStatus={false}
              style={style}
            />
          );
        }}
      />
    </MenuSourceContext>
  );
}

const INBOX_TITLES: Record<InboxGroupId, string> = {
  needsInput: "inbox.needsInput",
  review: "inbox.review",
  failed: "inbox.failed",
  mine: "inbox.mine",
  rest: "inbox.rest",
};

type InboxRow = { kind: "group"; id: InboxGroupId; count: number } | { kind: "zero" } | { kind: "task"; task: Task };

/** Variant `inbox`: what needs a person first, then the rest; the detail on the right. */
function InboxLayout({ store, state, strings }: LayoutProps) {
  const groups = useMemo(() => inboxGroups(state.shown, state.mirror.me), [state.shown, state.mirror.me]);
  const rows = useMemo(() => {
    const out: InboxRow[] = [];
    for (const group of groups) {
      if (!group.tasks.length) continue;
      out.push({ kind: "group", id: group.id, count: group.tasks.length });
      for (const task of group.tasks) out.push({ kind: "task", task });
    }
    const attention = groups.filter(
      (group) => group.id === "needsInput" || group.id === "review" || group.id === "failed",
    );
    if (attention.every((group) => !group.tasks.length)) out.push({ kind: "zero" });
    return out;
  }, [groups]);
  // Pick the first task once; later owner events never change what the detail shows.
  const picked = useRef(false);
  useEffect(() => {
    if (picked.current || state.connection !== "connected") return;
    picked.current = true;
    if (!state.selection) store.select(firstInboxTask(groups)?.id);
  }, [groups, state.connection, state.selection, store]);
  const byId = useMemo(() => new Map(state.tasks.map((task) => [task.id, task])), [state.tasks]);
  const selected = state.selection === undefined ? undefined : byId.get(state.selection);
  const { shared, marks, menu, statusById } = useRows({ store, state, strings });
  return (
    <MenuSourceContext value={menu}>
      <div className="tasks-inbox">
        <VirtualList
          className="tasks-list tasks-inbox-list"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList's role prop, its scroller is a div
          role="list"
          label={strings.t("pane.title")}
          count={rows.length}
          estimateSize={(index) => (rows[index]!.kind === "task" ? ROW_HEIGHT : HEADER_HEIGHT)}
          renderRow={(index, style) => {
            const row = rows[index]!;
            if (row.kind === "zero") {
              return (
                <p key="zero" className="tasks-inbox-zero" style={style}>
                  {strings.t("inbox.zero")}
                </p>
              );
            }
            if (row.kind === "group") {
              return (
                <div key={`g:${row.id}`} className="tasks-group-header" style={style} role="presentation">
                  <span className="tasks-group-title">{strings.t(INBOX_TITLES[row.id])}</span>
                  <span className="tasks-count">{row.count}</span>
                </div>
              );
            }
            return (
              <TaskRow
                key={row.task.id}
                {...shared}
                task={row.task}
                labels={labelsFor(state.mirror.labels, row.task)}
                selected={state.selection === row.task.id}
                pending={marks.pending.has(row.task.id)}
                unsent={marks.unsent.get(row.task.id)}
                status={statusById.get(row.task.status)}
                showStatus
                style={style}
              />
            );
          }}
        />
        <div className="tasks-detail-pane">
          <div className="tasks-detail-scroll">
            {selected ? <TaskDetail store={store} state={state} strings={strings} task={selected} /> : null}
          </div>
          {/* Its line is the split's divider and drags as one (ui/SplitEdge.tsx). */}
          <SplitEdge
            side="start"
            property="--tasks-detail-width"
            storageKey="cmux.tasks.detail.width"
            min={280}
            max={960}
            on="parent"
          />
        </div>
      </div>
    </MenuSourceContext>
  );
}

const SESSION_KEYS: Record<Session["status"], string> = {
  pending: "session.starting",
  claimed: "session.starting",
  working: "session.working",
  awaiting_input: "session.waiting",
  done: "session.done",
  failed: "session.failed",
  canceled: "session.canceled",
};

/** The selected task: title, status, assignee and its agent session with the plan. */
function TaskDetail({ store, state, strings, task }: LayoutProps & { task: Task }) {
  const status = statusOf(state.mirror.statuses, task);
  const session = sessionFor(state.mirror, task.id);
  const entries = assigneeEntries(state.mirror, state.tasks, strings);
  const groups: [AssigneeEntry["group"], string | null][] = [
    ["people", strings.t("assignee.people")],
    ["agents", strings.t("assignee.agents")],
    ["nobody", null],
  ];
  return (
    <article className="tasks-detail" aria-label={task.title}>
      <div className="tasks-detail-bar">
        <span className="tasks-key">{task.key}</span>
        {status ? (
          <Menu>
            <MenuButton className="tasks-plain-button" label={status.name} data-menu="status">
              <StatusMark category={status.category} color={status.color} />
              <span>{status.name}</span>
            </MenuButton>
            <MenuPopup align="start">
              {state.mirror.statuses.map((candidate) => (
                <MenuCheckboxItem
                  key={candidate.id}
                  checked={candidate.id === task.status}
                  disabled={candidate.id === task.status}
                  onCheckedChange={() => store.setStatus(task.id, candidate.id)}
                >
                  {candidate.name}
                </MenuCheckboxItem>
              ))}
            </MenuPopup>
          </Menu>
        ) : null}
        <PriorityMark priority={task.priority} />
        <span className="tasks-spacer" />
        <Menu>
          <MenuButton
            className="tasks-plain-button"
            label={strings.t("assignee.title")}
            title={strings.t("assignee.title")}
            data-menu="assignee"
          >
            <AssigneeBadge assignee={task.assignee} delegate={task.delegate} strings={strings} />
          </MenuButton>
          <MenuPopup align="end">
            {groups.map(([group, title], index) => {
              const rows = entries
                .filter((entry) => entry.group === group)
                .map((entry) => (
                  <MenuCheckboxItem
                    key={entry.id}
                    checked={isCurrentChoice(state.mirror, task, entry.choice)}
                    onCheckedChange={() => void store.choose(task.id, entry.choice)}
                  >
                    {entry.label}
                  </MenuCheckboxItem>
                ));
              return (
                <div key={group}>
                  {index > 0 ? <MenuSeparator /> : null}
                  {title ? <MenuGroup label={title}>{rows}</MenuGroup> : rows}
                </div>
              );
            })}
          </MenuPopup>
        </Menu>
      </div>
      <h2 className="tasks-detail-title">{task.title}</h2>
      <LabelChips labels={labelsOf(state.mirror.labels, task)} />
      {session ? <SessionCard session={session} strings={strings} /> : null}
    </article>
  );
}

function SessionCard({ session, strings }: { session: Session; strings: Strings }) {
  return (
    <section className="tasks-session">
      <div className="tasks-session-head">
        <span className="tasks-session-mark" style={{ color: ansi(5) }}>
          <AgentMark agent={session.agent.harness} size={12} />
        </span>
        <span className="tasks-session-agent">{agentName(session.agent.harness)}</span>
        <span className={`tasks-session-status ${session.status}`}>{strings.t(SESSION_KEYS[session.status])}</span>
      </div>
      {session.plan.length ? (
        <>
          <h3>{strings.t("detail.plan")}</h3>
          <ol className="tasks-plan">
            {session.plan.map((step, index) => (
              <li key={index} className={step.status === "completed" ? "done" : undefined}>
                <Icon
                  name={
                    step.status === "completed"
                      ? "status.complete"
                      : step.status === "in_progress"
                        ? "status.inprogress"
                        : "state.idle"
                  }
                  size={12}
                />
                <span>{step.content}</span>
              </li>
            ))}
          </ol>
        </>
      ) : null}
    </section>
  );
}

/** Variant `board`: a column per status; dropping a card on another column changes its status. */
function BoardLayout({ store, state, strings }: LayoutProps) {
  const groups = useMemo(() => statusGroups(state.mirror.statuses, state.shown), [state.mirror.statuses, state.shown]);
  const sessions = useMemo(() => sessionsByTask(state.mirror.sessions), [state.mirror.sessions]);
  const { shared, marks, menu } = useRows({ store, state, strings });
  const [target, setTarget] = useState<string | null>(null);
  const onDrop = (status: string) => (event: DragEvent) => {
    event.preventDefault();
    setTarget(null);
    const id = event.dataTransfer.getData("application/x-cmux-task") || event.dataTransfer.getData("text/plain");
    if (id) store.setStatus(id, status);
  };
  return (
    <MenuSourceContext value={menu}>
      <div className="tasks-board">
        {groups.map(({ status, tasks }) => (
          <section
            key={status.id}
            className={`tasks-column${target === status.id ? " targeted" : ""}`}
            aria-label={status.name}
            onDragOver={(event) => {
              event.preventDefault();
              event.dataTransfer.dropEffect = "move";
              if (target !== status.id) setTarget(status.id);
            }}
            onDragLeave={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setTarget(null);
            }}
            onDrop={onDrop(status.id)}
          >
            <StatusHeader status={status} count={tasks.length} />
            <VirtualList
              className="tasks-column-list"
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- VirtualList's role prop, its scroller is a div
              role="list"
              label={status.name}
              count={tasks.length}
              estimateSize={() => 96}
              // A card grows with its title (up to three lines) and session progress: each slot is measured
              // (TanStack's one ResizeObserver watches the mounted cards only).
              measureRows
              // A card keeps its measured height when a card above it moves to another column.
              itemKey={(index) => tasks[index]!.id}
              renderRow={(index, style, measure) => {
                const task = tasks[index]!;
                return (
                  <BoardCard
                    key={task.id}
                    {...shared}
                    task={task}
                    labels={labelsFor(state.mirror.labels, task)}
                    session={sessions.get(task.id)}
                    selected={state.selection === task.id}
                    pending={marks.pending.has(task.id)}
                    unsent={marks.unsent.get(task.id)}
                    style={style}
                    index={index}
                    measure={measure}
                  />
                );
              }}
            />
          </section>
        ))}
      </div>
    </MenuSourceContext>
  );
}

interface BoardCardProps extends RowShared {
  task: Task;
  /** The task's labels (`labelsFor`). */
  labels: readonly Label[];
  session: Session | undefined;
  selected: boolean;
  pending: boolean;
  unsent: Intent | undefined;
  style: CSSProperties;
  index: number;
  measure?: (element: Element | null) => void;
}

const BoardCard = memo(function BoardCard({
  store,
  strings,
  labels,
  task,
  session,
  selected,
  pending,
  unsent,
  style,
  index,
  measure,
}: BoardCardProps) {
  const done = session ? session.plan.filter((step) => step.status === "completed").length : 0;
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a virtualized row (absolute, transformed), not a flow <li>
    <div ref={measure} data-index={index} style={style} className="tasks-card-slot" role="listitem">
      <TaskMenu task={task}>
        <button
          type="button"
          data-focus-ring="row"
          aria-current={selected || undefined}
          className={`tasks-card${selected ? " selected" : ""}${pending ? " pending" : ""}`}
          draggable
          data-task={task.id}
          onDragStart={(event) => {
            event.dataTransfer.setData("application/x-cmux-task", task.id);
            event.dataTransfer.setData("text/plain", task.id);
            event.dataTransfer.effectAllowed = "move";
          }}
          onClick={() => store.select(task.id)}
        >
          <span className="tasks-card-head">
            <span className="tasks-key">{task.key}</span>
            <AttentionDot attention={task.attention} strings={strings} />
            <span className="tasks-spacer" />
            <AssigneeBadge assignee={task.assignee} delegate={task.delegate} strings={strings} size={16} />
          </span>
          <span className="tasks-card-title">{task.title}</span>
          {session && session.plan.length ? (
            <span className="tasks-plan-progress">
              <Progress done={done} total={session.plan.length} />
              <span>{strings.t(SESSION_KEYS[session.status])}</span>
            </span>
          ) : null}
          <span className="tasks-card-foot">
            <PriorityMark priority={task.priority} />
            <LabelChips labels={labels} />
          </span>
        </button>
      </TaskMenu>
      <RowUnsent store={store} strings={strings} intent={unsent} />
    </div>
  );
});
