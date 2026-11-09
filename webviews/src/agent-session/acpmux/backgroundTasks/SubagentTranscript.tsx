// A subagent's transcript inside the Background tasks panel (BackgroundTasksPanel.tsx): its replies,
// and between them its work: a stretch of two or more tool calls folds under one quiet line, "Ran 11
// commands, read a file, 2 failed", which opens to its steps, each thought under "Thought process" and
// each call on a line that opens to what it ran and said; a lone call keeps its own line. The shared
// spinner sits under the last row while it runs. Claude Code's drill-in, in our type (Leo, 2026-11-09:
// "this claude background tasks thing and being able to click into subagents'/helpers' stuff is really
// good"); before, every call and every thought drew a line of its own (transcriptRuns.experiment.ts
// keeps that as its `lines` arm).
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
import { Button } from "../../../ui/Button";
import { memo, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { entranceAllowed } from "../../shared/pageReveal";
import { useFold } from "../conversation/fold";
import { Markdown } from "../conversation/Markdown";
import { Spinner } from "../conversation/icons";
import { toolRunSummary } from "../conversation/toolRunSummary";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";
import {
  WINDOW,
  MOUNTED,
  windowRange,
  NestedAgents,
  runFold,
  carryRange,
  type Range,
  transcriptBlocks,
  type TranscriptBlock,
} from "./subagentTranscriptModel";
import { transcriptRunsLook } from "./transcriptRuns.experiment";
/// A tool call's output shown when opened, at most (the full output stays in the transcript).
const OUTPUT_CHARS = 4000;
/// How close to the bottom counts as at the bottom, in px.
const BOTTOM_SLACK = 24;

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

/// A row the transcript drew is gone. Streaming keeps every row where it was and appends below, so the
/// common case is one pass comparing ids in place, with nothing allocated; only rows that moved build a
/// set.
function rowsRemoved(prev: readonly AcpmuxRow[], next: readonly AcpmuxRow[]): boolean {
  if (next.length < prev.length) return true;
  let index = 0;
  while (index < prev.length && prev[index]!.id === next[index]!.id) index += 1;
  if (index === prev.length) return false;
  const ids = new Set(next.map((row) => row.id));
  return prev.some((row) => !ids.has(row.id));
}

/// A block the transcript drew starts somewhere else now, or a block before the newest changed what it
/// holds (a fold, rows read in above): the window's indices no longer name the same rows.
function blocksMoved(prev: readonly TranscriptBlock[], next: readonly TranscriptBlock[]): boolean {
  if (next.length < prev.length) return true;
  for (let index = 0; index < prev.length; index += 1) {
    const a = prev[index]!;
    const b = next[index]!;
    if (a.id !== b.id || a.type !== b.type) return true;
  }
  return false;
}

/// `current` when `next` mounts the same blocks, so an update that moves nothing renders nothing more.
const sameRange = (current: Range, next: Range): Range =>
  current.start === next.start && current.end === next.end ? current : next;

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
  // Read once per transcript: the arm is the gallery's override or a dogfood key, never a per-row read.
  const [look] = useState(() => experimentArm(transcriptRunsLook));
  // Which runs the reader opened or shut, by their rows' ids: a run is the same run however the
  // mounted window cuts it, and the task opened from the list opens the run that holds it.
  const [opened, setOpened] = useState<ReadonlySet<string>>(() => new Set(anchor ? [anchor] : []));
  const [shut, setShut] = useState<ReadonlySet<string>>(() => new Set());
  // The window counts what the transcript draws (transcriptBlocks): a reply, a lone call, or a whole
  // run of work folded under one line, so a long run never leaves the window too short to scroll
  // (two sentinels in view, paging back and forth by themselves). The task opened from the list
  // anchors the window on the block that holds it.
  const units = useMemo(() => transcriptBlocks(rows, runFold(look)), [rows, look]);
  const anchorUnit =
    anchor === undefined
      ? undefined
      : units.find((unit) => (unit.type === "row" ? unit.id === anchor : unit.rows.some((row) => row.id === anchor)))
          ?.id;
  const [range, setRange] = useState(() => windowRange(units, anchorUnit));
  // Opened before acpmux streamed any of its rows: the window is taken from the first rows that
  // arrive, so a long transcript still mounts one window, not every row.
  const [seeded, setSeeded] = useState(units.length > 0);
  if (!seeded && units.length > 0) {
    setSeeded(true);
    setRange(windowRange(units, anchorUnit));
  }
  // Rows removed (a workflow agent's transcript read again from a fresh page after its file was cut or
  // replaced: a row the transcript drew is gone): the window is taken again from the new rows, never
  // left past their end. Otherwise the same rows may draw as other blocks: work rows folded into one
  // run as a call streams in, older history read in above the first row, both with rows appended
  // below. carryRange moves each end of the window to the block that now holds its row, so the rows
  // the reader was on stay the ones mounted. A row is the same row by its id: a page that reuses ids
  // for other content reads as the same rows changing, as a streaming update does.
  const [seen, setSeen] = useState({ rows, units });
  if (rows !== seen.rows || units !== seen.units) {
    const before = seen;
    setSeen({ rows, units });
    if (rowsRemoved(before.rows, rows)) setRange(windowRange(units));
    else if (before.units.length > 0 && blocksMoved(before.units, units))
      setRange((current) => sameRange(current, carryRange(before.units, units, current)));
  }
  const atBottom = useRef(anchor === undefined);
  // While the mounted window moves (rows added above, rows unmounted above, older text merged into a
  // row): the row the reader is on and where its bottom edge sat in the view. Each render puts that
  // edge back where it was (a no-op once it is), so nothing the reader sees moves; with that row gone
  // (rows replaced), the distance from the bottom holds instead. `settled` once the rows are in: the
  // next render applies it and lets go.
  const held = useRef<Hold | undefined>(undefined);
  const placed = useRef(false);
  const first = Math.min(range.start, Math.max(0, units.length - 1));
  const last = range.end === undefined || range.end >= units.length ? undefined : range.end;
  const blocks = units.slice(first, last);
  const tail = blocks.at(-1);
  const lastRun = tail?.type === "run" ? tail.id : undefined;
  const loadOlder = onLoadOlder;

  // Before the first paint: at the bottom, or the opened task's row in view.
  useLayoutEffect(() => {
    const view = scroller.current;
    if (!view) return;
    if (!placed.current) {
      if (units.length === 0) return;
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

  // Rows streaming in keep the mounted units bounded. Following the newest row, once a window's worth
  // has streamed in under the reader, the units above the newest window unmount (the top sentinel
  // brings them back). Scrolled up, the window stops following at MOUNTED units, so nothing above
  // the reader moves; the bottom sentinel mounts the rest as they scroll down.
  useLayoutEffect(() => {
    if (range.end !== undefined || units.length - range.start <= MOUNTED) return;
    setRange(atBottom.current ? { start: units.length - WINDOW } : { start: range.start, end: range.start + MOUNTED });
  }, [units.length, range]);

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
    // Each move keeps at most MOUNTED units: a window gained at one end unmounts as many at the other.
    if (first > 0)
      watch(top.current, "200px 0px 0px 0px", () => {
        held.current = capture(view, true);
        const start = Math.max(0, first - WINDOW);
        const end = last ?? units.length;
        setRange(end - start > MOUNTED ? { start, end: start + MOUNTED } : { start, end: last });
      });
    else if (loadOlder && units.length > 0)
      watch(top.current, "200px 0px 0px 0px", () => {
        const hold = capture(view, false);
        held.current = hold;
        // The older page's units are set before the read settles, so the render that draws them comes
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
          end >= units.length
            ? { start: Math.max(first, units.length - MOUNTED) }
            : { start: Math.max(first, end - MOUNTED), end },
        );
      });
    return () => observers.forEach((observer) => observer.disconnect());
  }, [first, last, units.length, loadOlder]);

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
      {blocks.map((block) => {
        if (block.type === "row")
          return <TranscriptRow key={block.row.id} row={block.row} version={block.row.version} />;
        const ids = block.rows.map((row) => row.id);
        const isOpen =
          !ids.some((id) => shut.has(id)) &&
          (ids.some((id) => opened.has(id)) || (look === "live" && block.running && block.id === lastRun));
        return (
          <RunLine
            key={block.id}
            run={block}
            open={isOpen}
            onToggle={() => {
              const without = (set: ReadonlySet<string>) => new Set([...set].filter((id) => !ids.includes(id)));
              setOpened((now) => (isOpen ? without(now) : new Set([...now, ...ids])));
              setShut((now) => (isOpen ? new Set([...now, ...ids]) : without(now)));
            }}
          />
        );
      })}
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

/// A run of work between two replies: one quiet line naming what it did, "Ran 11 commands, read a file,
/// 2 failed" (the failures in the danger colour), that opens in place to its steps on the shared fold.
/// Folded, it carries its first row's id, so the panel's scroll hold and the opened task find it.
function RunLine({
  run,
  open,
  onToggle,
}: {
  run: Extract<TranscriptBlock, { type: "run" }>;
  open: boolean;
  onToggle(): void;
}) {
  const t = useT();
  const fold = useFold(open, entranceAllowed);
  return (
    <div className="acpmux-bg__run" data-run-id={run.id} data-row-id={open ? undefined : run.id}>
      <Button
        variant="ghost"
        size="sm"
        type="button"
        className="acpmux-bg__line acpmux-bg__line--fold"
        aria-expanded={open}
        onClick={onToggle}
      >
        {run.running ? <Spinner size={12} loading /> : null}
        {/* The failures sit outside the summary that ellipsizes: a long summary never cuts them. */}
        <span className="acpmux-bg__run-name">
          <span className="acpmux-bg__label">{toolRunSummary(t, run.items)}</span>
          {run.failed > 0 && (
            <>
              <span className="acpmux-bg__run-sep">{t("toolRun.separator")}</span>
              <span className="acpmux-bg__failed acpmux-bg__run-sep">
                {t("backgroundTasks.failed", { n: run.failed })}
              </span>
            </>
          )}
        </span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />
      </Button>
      {fold.present && (
        <div ref={fold.ref} className="acpmux-bg__run-steps" inert={!open || undefined}>
          {run.rows.map((row) => (
            <TranscriptRow key={row.id} row={row} version={row.version} />
          ))}
        </div>
      )}
    </div>
  );
}

function NestedAgent({ id, name, running, opens }: { id: string; name: string; running: boolean; opens: boolean }) {
  const { open: openAgent, stop } = useContext(NestedAgents);
  const open = opens ? openAgent : undefined;
  return (
    <div className="acpmux-bg__task" data-state={running ? "running" : "done"}>
      <Button
        variant="ghost"
        type="button"
        className="acpmux-bg__task-open"
        disabled={!open}
        onClick={() => open?.(id)}
      >
        {running ? (
          <Spinner size={12} loading />
        ) : (
          <span className="acpmux-bg__disclosure" aria-hidden="true">
            <Icon name="disclosure.collapsed" size={12} row />
          </span>
        )}
        <span className="acpmux-bg__label">{name}</span>
      </Button>
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
      <Button
        variant="ghost"
        size="sm"
        type="button"
        className="acpmux-bg__line acpmux-bg__line--fold"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span>{t("backgroundTasks.thought")}</span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />
      </Button>
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
      <Button
        variant="ghost"
        size="sm"
        type="button"
        className="acpmux-bg__line acpmux-bg__line--fold"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        {call.status === "in_progress" || call.status === "pending" ? <Spinner size={12} loading /> : null}
        <span className="acpmux-bg__label">{title}</span>
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} row />
      </Button>
      {open && (ran || output) && (
        <pre className="acpmux-bg__output">
          {ran && <code className="acpmux-bg__ran">{ran}</code>}
          {output && <code>{output}</code>}
        </pre>
      )}
    </div>
  );
}
