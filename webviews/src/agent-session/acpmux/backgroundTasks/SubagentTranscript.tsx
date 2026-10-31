// A subagent's transcript inside the Background tasks panel (BackgroundTasksPanel.tsx): its replies,
// its thoughts folded under "Thought process" and its tool calls one line each, which open to what
// they ran and said, with the shared spinner under the last row while it runs. Claude Desktop's
// drill-in, in our type.
//
// It draws on the click with no blank frame and no jump (Leo, 2026-10-29: "i also like the way it
// just loads in the subagent stuff instantly :("):
// - the rows are the subagent's view acpmux already streamed into the chat's snapshot
//   (`subagentViews`, subagentFold.ts), so the first paint never waits on the daemon;
// - only the newest WINDOW rows mount at first, placed at the bottom (or around the task opened)
//   in a layout effect, before the frame paints; older rows mount a window at a time as the reader
//   scrolls up to the top sentinel, with the scroll offset held so nothing moves;
// - while the reader is at the bottom, a new row keeps them there; scrolled up, at most MOUNTED rows
//   stay mounted as rows stream in, and the bottom sentinel mounts the rest;
// - a workflow agent's transcript (read a page at a time through acpmux) loads its older history from
//   the same top sentinel once every row it has is mounted (`onLoadOlder`), with the offset held too.
// The sentinels' IntersectionObservers (one above the mounted rows, one below a window opened around
// a task) are the only observers here: each disconnects when it fires, once every row on its side is
// mounted, and on unmount.
import { createContext, memo, useContext, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Markdown } from "../conversation/Markdown";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";

/// Rows mounted at first, and how many more each scroll to the top adds.
export const WINDOW = 60;
/// A tool call's output shown when opened, at most (the full output stays in the transcript).
const OUTPUT_CHARS = 4000;
/// How close to the bottom counts as at the bottom, in px.
const BOTTOM_SLACK = 24;

/// The rows mounted at first, bounded at both ends: `end` undefined follows the newest row (the
/// newest window, which grows as rows arrive); a window around an anchor row ends WINDOW rows on, so
/// opening a task early in a long transcript mounts no more than one window either way.
export type Range = { start: number; end?: number };

/// The most rows mounted at once while the reader pages up or down: one window gained, one kept.
export const MOUNTED = 2 * WINDOW;

type Hold = { id?: string; edge: number; fromBottom: number; settled: boolean };

/// The first row the reader sees (its bottom edge below the view's top) and where that edge sits.
function capture(view: HTMLElement, settled: boolean): Hold {
  const fromBottom = view.scrollHeight - view.scrollTop;
  const top = view.getBoundingClientRect().top;
  for (const row of view.querySelectorAll<HTMLElement>("[data-row-id]")) {
    const edge = row.getBoundingClientRect().bottom - top;
    if (edge > 0) return { id: row.dataset.rowId, edge, fromBottom, settled };
  }
  return { edge: 0, fromBottom, settled };
}

/// Puts the held row's bottom edge back where it was; with that row gone, the distance from the bottom.
function restore(view: HTMLElement, hold: Hold) {
  const row = hold.id ? view.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(hold.id)}"]`) : null;
  if (!row) {
    view.scrollTop = view.scrollHeight - hold.fromBottom;
    return;
  }
  view.scrollTop += row.getBoundingClientRect().bottom - view.getBoundingClientRect().top - hold.edge;
}

export function windowRange(rows: readonly AcpmuxRow[], anchor?: string): Range {
  const newest = Math.max(0, rows.length - WINDOW);
  const at = anchor === undefined ? -1 : rows.findIndex((row) => row.id === anchor);
  if (at < 0) return { start: newest };
  const start = Math.min(newest, Math.max(0, at - Math.floor(WINDOW / 4)));
  const end = start + WINDOW;
  return end >= rows.length ? { start } : { start, end };
}

export function SubagentTranscript({
  rows,
  running,
  anchor,
  onLoadOlder,
  notice,
}: {
  rows: readonly AcpmuxRow[];
  running: boolean;
  /// The row of the task that was opened: the transcript opens on it.
  anchor?: string;
  /// Set while older history can be read (a workflow agent's transcript): reaching the top reads it.
  onLoadOlder?: () => Promise<unknown>;
  /// A line above the rows (a workflow agent's transcript: Loading, or why it is short).
  notice?: string;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const top = useRef<HTMLDivElement>(null);
  const bottom = useRef<HTMLDivElement>(null);
  const [range, setRange] = useState(() => windowRange(rows, anchor));
  // Opened before acpmux streamed any of its rows: the window is taken from the first rows that
  // arrive, so a long transcript still mounts one window, not every row.
  const [seeded, setSeeded] = useState(rows.length > 0);
  if (!seeded && rows.length > 0) {
    setSeeded(true);
    setRange(windowRange(rows, anchor));
  }
  // Rows replaced by fewer (a workflow agent's transcript read again from a fresh page after its file
  // was cut or replaced): the window is taken again from the new rows, never left past their end.
  // Rows read in above the first one (a workflow agent's older history): the window moves down by as
  // many, so the rows the reader was on stay the ones mounted.
  const [seen, setSeen] = useState({ count: rows.length, head: rows[0]?.id });
  if (rows.length !== seen.count || rows[0]?.id !== seen.head) {
    setSeen({ count: rows.length, head: rows[0]?.id });
    if (rows.length < seen.count) setRange(windowRange(rows));
    else if (seen.head !== undefined && rows[0]?.id !== seen.head) {
      const moved = rows.findIndex((row) => row.id === seen.head);
      if (moved < 0) setRange(windowRange(rows));
      else
        setRange((current) => ({
          start: current.start + moved,
          end: current.end === undefined ? undefined : current.end + moved,
        }));
    }
  }
  const atBottom = useRef(anchor === undefined);
  // While the mounted window moves (rows added above, rows unmounted above, older text merged into a
  // row): the row the reader is on and where its bottom edge sat in the view. Each render puts that
  // edge back where it was (a no-op once it is), so nothing the reader sees moves; with that row gone
  // (rows replaced), the distance from the bottom holds instead. `settled` once the rows are in: the
  // next render applies it and lets go.
  const held = useRef<Hold | undefined>(undefined);
  const placed = useRef(false);
  const first = Math.min(range.start, Math.max(0, rows.length - 1));
  const last = range.end === undefined || range.end >= rows.length ? undefined : range.end;
  const shown = rows.slice(first, last);
  const loadOlder = onLoadOlder;

  // Before the first paint: at the bottom, or the opened task's row in view.
  useLayoutEffect(() => {
    const view = scroller.current;
    if (!view) return;
    if (!placed.current) {
      if (rows.length === 0) return;
      placed.current = true;
      const target = anchor ? view.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(anchor)}"]`) : null;
      if (target) view.scrollTop = Math.max(0, target.offsetTop - view.clientHeight / 3);
      else view.scrollTop = view.scrollHeight;
      return;
    }
    // The window moved: hold what the reader sees where it was.
    if (held.current !== undefined) {
      restore(view, held.current);
      if (held.current.settled) held.current = undefined;
      return;
    }
    if (atBottom.current && last === undefined) view.scrollTop = view.scrollHeight;
  });

  // Rows streaming in keep the mounted rows bounded. Following the newest row, once a window's worth
  // has streamed in under the reader, the rows above the newest window unmount (the top sentinel
  // brings them back). Scrolled up, the window stops following at MOUNTED rows, so nothing above
  // the reader moves; the bottom sentinel mounts the rest as they scroll down.
  useLayoutEffect(() => {
    if (range.end !== undefined || rows.length - range.start <= MOUNTED) return;
    setRange(atBottom.current ? { start: rows.length - WINDOW } : { start: range.start, end: range.start + MOUNTED });
  }, [rows.length, range]);

  // Scrolling up to the top sentinel mounts the window before it, holding the scroll; scrolling
  // down to the bottom one (a window around an anchor) mounts the window after it, and the one
  // that reaches the newest row follows it from then on.
  useEffect(() => {
    const view = scroller.current;
    if (!view || typeof IntersectionObserver === "undefined") return;
    const observers: IntersectionObserver[] = [];
    const watch = (sentinel: HTMLElement | null, margin: string, grow: () => void) => {
      if (!sentinel) return;
      const observer = new IntersectionObserver(
        (entries) => {
          if (!entries.some((entry) => entry.isIntersecting)) return;
          observer.disconnect();
          grow();
        },
        { root: view, rootMargin: margin },
      );
      observer.observe(sentinel);
      observers.push(observer);
    };
    // Each move keeps at most MOUNTED rows: a window gained at one end unmounts as many at the other.
    if (first > 0)
      watch(top.current, "200px 0px 0px 0px", () => {
        held.current = capture(view, true);
        const start = Math.max(0, first - WINDOW);
        const end = last ?? rows.length;
        setRange(end - start > MOUNTED ? { start, end: start + MOUNTED } : { start, end: last });
      });
    else if (loadOlder && rows.length > 0)
      watch(top.current, "200px 0px 0px 0px", () => {
        const hold = capture(view, false);
        held.current = hold;
        // The older page's rows are set before the read settles, so the render that draws them comes
        // after this: it holds the scroll once more, then lets go.
        void loadOlder()
          .catch(() => undefined)
          .finally(() => {
            hold.settled = true;
          });
      });
    if (last !== undefined)
      watch(bottom.current, "0px 0px 200px 0px", () => {
        held.current = capture(view, true);
        const end = last + WINDOW;
        // The window that reaches the newest row follows it from then on.
        setRange(
          end >= rows.length
            ? { start: Math.max(first, rows.length - MOUNTED) }
            : { start: Math.max(first, end - MOUNTED), end },
        );
      });
    return () => observers.forEach((observer) => observer.disconnect());
  }, [first, last, rows.length, loadOlder]);

  return (
    <div
      ref={scroller}
      className="acpmux-bg__transcript"
      onScroll={(event) => {
        const view = event.currentTarget;
        atBottom.current = view.scrollHeight - view.scrollTop - view.clientHeight <= BOTTOM_SLACK;
      }}
    >
      {notice && <p className="acpmux-bg__notice">{notice}</p>}
      {(first > 0 || loadOlder) && <div ref={top} className="acpmux-bg__sentinel" aria-hidden="true" />}
      {shown.map((row) => (
        <TranscriptRow key={row.id} row={row} version={row.version} />
      ))}
      {last !== undefined && <div ref={bottom} className="acpmux-bg__sentinel" aria-hidden="true" />}
      {running && last === undefined && (
        <div className="acpmux-bg__working">
          <Spinner size={14} loading />
        </div>
      )}
    </div>
  );
}

/// One row, redrawn only when its version moves or its reply settles.
const TranscriptRow = memo(
  function TranscriptRow({ row }: { row: AcpmuxRow; version: number }) {
    if (row.kind === "assistant" && row.text)
      return (
        <div className="acpmux-bg__reply" data-row-id={row.id}>
          <Markdown streaming={row.streaming === true}>{row.text}</Markdown>
        </div>
      );
    if (row.kind === "user" && row.text)
      return (
        <p className="acpmux-bg__prompt" data-row-id={row.id}>
          {row.text}
        </p>
      );
    if (row.kind === SUBAGENTS)
      return (
        <div data-row-id={row.id}>
          {(row.subagents ?? []).map((agent) => (
            <NestedAgent
              key={agent.id}
              id={agent.id}
              name={agent.task?.trim() || agent.name}
              running={agent.state === "running" && !(agent.kind === "workflow" && agent.paused)}
              // A workflow has no transcript of its own (its agents' are listed in the panel).
              opens={agent.kind !== "workflow"}
            />
          ))}
        </div>
      );
    const items = row.items ?? [];
    if (items.length === 0) return null;
    return (
      <div data-row-id={row.id}>
        {items.map((item, index) =>
          item.kind === "thought" ? (
            <Thought key={index} text={item.text} />
          ) : item.kind === "tool" && item.tool ? (
            <ToolLine key={item.tool.id} item={item} />
          ) : null,
        )}
      </div>
    );
  },
  // A reply settles (`streaming` goes false) without a new version when its agent completes.
  (a, b) => a.row.id === b.row.id && a.version === b.version && a.row.streaming === b.row.streaming,
);

/// What a nested agent's line in a transcript does (BackgroundTasksPanel.tsx provides it): it opens
/// that agent's own transcript, and while it runs it carries the agent's stop button, so an agent at
/// any depth opens and stops from the panel.
export const NestedAgents = createContext<{
  open?(agentId: string): void;
  stop?(agentId: string, name: string): ReactNode;
}>({});

function NestedAgent({ id, name, running, opens }: { id: string; name: string; running: boolean; opens: boolean }) {
  const { open: openAgent, stop } = useContext(NestedAgents);
  const open = opens ? openAgent : undefined;
  return (
    <div className="acpmux-bg__task" data-state={running ? "running" : "done"}>
      <button type="button" className="acpmux-bg__task-open" disabled={!open} onClick={() => open?.(id)}>
        {running ? (
          <Spinner size={10} loading />
        ) : (
          <span className="acpmux-bg__disclosure" aria-hidden="true">
            <Icon name="disclosure.collapsed" size={10} row />
          </span>
        )}
        <span className="acpmux-bg__label">{name}</span>
      </button>
      {running && stop?.(id, name)}
    </div>
  );
}

function Thought({ text }: { text: string }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  if (!text.trim()) return null;
  return (
    <div className="acpmux-bg__thought">
      <button
        type="button"
        className="acpmux-bg__line acpmux-bg__line--fold"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span>{t("backgroundTasks.thought")}</span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={10} row />
      </button>
      {open && <p className="acpmux-bg__thought-text">{text}</p>}
    </div>
  );
}

function ToolLine({ item }: { item: AcpmuxActivity }) {
  const [open, setOpen] = useState(false);
  const call = item.tool!;
  const title = call.description?.trim() || call.title || item.text;
  const ran = call.command ?? call.inputSummary;
  const output = call.output ? call.output.slice(-OUTPUT_CHARS) : undefined;
  const failed = call.status === "failed";
  return (
    <div className="acpmux-bg__tool" data-failed={failed || undefined}>
      <button
        type="button"
        className="acpmux-bg__line acpmux-bg__line--fold"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        {call.status === "in_progress" || call.status === "pending" ? <Spinner size={10} loading /> : null}
        <span className="acpmux-bg__label">{title}</span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={10} row />
      </button>
      {open && (ran || output) && (
        <pre className="acpmux-bg__output">
          {ran && <code className="acpmux-bg__ran">{ran}</code>}
          {output && <code>{output}</code>}
        </pre>
      )}
    </div>
  );
}
