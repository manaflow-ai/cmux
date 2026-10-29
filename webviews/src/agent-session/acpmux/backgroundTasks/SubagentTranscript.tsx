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
// The sentinel's IntersectionObserver is the one observer here: it disconnects once every row is
// mounted, and on unmount.
import { memo, useEffect, useLayoutEffect, useRef, useState } from "react";
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

/// Where the first mounted row is: the newest window, or one that holds the anchor row.
export function windowStart(rows: readonly AcpmuxRow[], anchor?: string): number {
  const newest = Math.max(0, rows.length - WINDOW);
  if (anchor === undefined) return newest;
  const at = rows.findIndex((row) => row.id === anchor);
  return at < 0 ? newest : Math.min(newest, Math.max(0, at - Math.floor(WINDOW / 4)));
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
  const [start, setStart] = useState(() => windowStart(rows, anchor));
  const atBottom = useRef(anchor === undefined);
  const grown = useRef<number | undefined>(undefined);
  const placed = useRef(false);
  const first = Math.min(start, Math.max(0, rows.length - 1));
  const shown = rows.slice(first);

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
    if (atBottom.current) view.scrollTop = view.scrollHeight;
  });

  // Scrolling up to the sentinel mounts the window before it.
  useEffect(() => {
    const view = scroller.current;
    const sentinel = top.current;
    if (!view || !sentinel || first === 0 || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        observer.disconnect();
        grown.current = view.scrollHeight;
        setStart(Math.max(0, first - WINDOW));
      },
      { root: view, rootMargin: "200px 0px 0px 0px" },
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [first]);

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
      {running && (
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
            <p key={agent.id} className="acpmux-bg__line">
              {agent.task?.trim() || agent.name}
            </p>
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

function Thought({ text }: { text: string }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  if (!text.trim()) return null;
  return (
    <div className="acpmux-bg__thought">
      <button type="button" className="acpmux-bg__line acpmux-bg__line--fold" aria-expanded={open} onClick={() => setOpen(!open)}>
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
      <button type="button" className="acpmux-bg__line acpmux-bg__line--fold" aria-expanded={open} onClick={() => setOpen(!open)}>
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
