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
// - while the reader is at the bottom, a new row keeps them there.
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
}: {
  rows: readonly AcpmuxRow[];
  running: boolean;
  /// The row of the task that was opened: the transcript opens on it.
  anchor?: string;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const top = useRef<HTMLDivElement>(null);
  const bottom = useRef<HTMLDivElement>(null);
  const [range, setRange] = useState(() => windowRange(rows, anchor));
  const atBottom = useRef(anchor === undefined);
  const grown = useRef<number | undefined>(undefined);
  const placed = useRef(false);
  const first = Math.min(range.start, Math.max(0, rows.length - 1));
  const last = range.end === undefined || range.end >= rows.length ? undefined : range.end;
  const shown = rows.slice(first, last);

  // Before the first paint: at the bottom, or the opened task's row in view.
  useLayoutEffect(() => {
    const view = scroller.current;
    if (!view) return;
    if (!placed.current) {
      placed.current = true;
      const target = anchor ? view.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(anchor)}"]`) : null;
      if (target) view.scrollTop = Math.max(0, target.offsetTop - view.clientHeight / 3);
      else view.scrollTop = view.scrollHeight;
      return;
    }
    // Older rows mounted above: hold what the reader sees where it was.
    if (grown.current !== undefined) {
      view.scrollTop += view.scrollHeight - grown.current;
      grown.current = undefined;
      return;
    }
    if (atBottom.current && last === undefined) view.scrollTop = view.scrollHeight;
  });

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
    if (first > 0)
      watch(top.current, "200px 0px 0px 0px", () => {
        grown.current = view.scrollHeight;
        setRange((now) => ({ ...now, start: Math.max(0, first - WINDOW) }));
      });
    if (last !== undefined)
      watch(bottom.current, "0px 0px 200px 0px", () =>
        setRange((now) => (last + WINDOW >= rows.length ? { start: now.start } : { ...now, end: last + WINDOW })),
      );
    return () => observers.forEach((observer) => observer.disconnect());
  }, [first, last, rows.length]);

  return (
    <div
      ref={scroller}
      className="acpmux-bg__transcript"
      onScroll={(event) => {
        const view = event.currentTarget;
        atBottom.current = view.scrollHeight - view.scrollTop - view.clientHeight <= BOTTOM_SLACK;
      }}
    >
      {first > 0 && <div ref={top} className="acpmux-bg__sentinel" aria-hidden="true" />}
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

/// One row, redrawn only when its version moves.
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
              running={agent.state === "running"}
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
  (a, b) => a.row.id === b.row.id && a.version === b.version,
);

/// What a nested agent's line in a transcript does (BackgroundTasksPanel.tsx provides it): it opens
/// that agent's own transcript, and while it runs it carries the agent's stop button, so an agent at
/// any depth opens and stops from the panel.
export const NestedAgents = createContext<{
  open?(agentId: string): void;
  stop?(agentId: string, name: string): ReactNode;
}>({});

function NestedAgent({ id, name, running }: { id: string; name: string; running: boolean }) {
  const { open, stop } = useContext(NestedAgents);
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
