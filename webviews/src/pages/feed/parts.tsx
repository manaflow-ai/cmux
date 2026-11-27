// The Feed's shared pieces: a row (FeedRowCells), its glyph and poster line (FeedGlyph), the empty
// state, the disconnected banner (FeedView), a request card (FeedListView's FeedRequestCard), the
// prompt summary (FeedPromptSummary) and the list that keeps only the rows in view (FeedRowsView).
import { memo, useMemo, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { sameJson } from "../../agent-session/acpmux/sameJson";
import { ConnectionChip } from "../../ui/ConnectionChip";
import { cx } from "../../ui/cx";
import type { Strings } from "../shared/i18n";
import { VirtualList } from "../../ui/VirtualList";
import { AnswerControls } from "./AnswerControls";
import { DiffLines, shownLine } from "./DiffLines";
import { FeedIcon, type FeedIconSize } from "./icons";
import {
  diffAttachment,
  fullDate,
  glyphTone,
  isLocal,
  isOpenRequest,
  isRequest,
  isUnread,
  lineHeight,
  metaLine,
  posterLabel,
  relativeTime,
  type FeedLine,
} from "./model";
import { plain, type AnswerState } from "./context";
import type { FeedStore } from "./store";
import type { FeedAttachment, ViewItem } from "./types";

// MARK: - Small pieces

export function Glyph({ item, size = 16 }: { item: ViewItem; size?: FeedIconSize }) {
  return (
    <span className="feed-glyph" data-tone={glyphTone(item)}>
      <FeedIcon name={item.row.icon} size={size} />
    </span>
  );
}

export function UnreadDot({ visible }: { visible: boolean }) {
  return <span className="feed-dot" data-visible={visible ? "" : undefined} aria-hidden="true" />;
}

/** "Claude Code · api-server · 3m", the local mark, "×2" (PosterLine). `time`: `relativeTime` of the
 * item's creation (the caller's clock; this never reads one). */
export function PosterLine({ item, strings, time }: { item: ViewItem; strings: Strings; time: string }) {
  return (
    <span className="feed-poster">
      <span className="feed-poster-label">{posterLabel(item)}</span>
      <span aria-hidden="true">·</span>
      {/* tooltip-allow: the shown time is relative; the tooltip is the one place its date shows. */}
      <time className="feed-num" title={fullDate(item.created_at, strings.language)}>
        {time}
      </time>
      {isLocal(item) ? (
        <span className="feed-local" title={strings.t("item.thisMac")}>
          <FeedIcon name="machine.local" size={12} />
        </span>
      ) : null}
      {(item.count ?? 1) > 1 ? <span className="feed-num">×{item.count}</span> : null}
    </span>
  );
}

export function EmptyState({ text, size = 32 }: { text: string; size?: 32 | 44 }) {
  return (
    <div className="feed-empty">
      <FeedIcon name="inbox.empty" size={size} />
      <span>{text}</span>
    </div>
  );
}

/** The owner is unreachable: a mark in the page's corner (ui/ConnectionChip.tsx), out of flow, so the
 *  list under it never moves when it comes or goes. Its sentence is the tooltip. */
export function Banner({ text }: { text: string }) {
  return <ConnectionChip text={text} />;
}

// MARK: - A row

export interface RowProps {
  line: Extract<FeedLine, { type: "row" }>;
  strings: Strings;
  /** The row's time, `relativeTime` of its item at the page's clock: a new clock that leaves the text
   * as it was renders no row. */
  time: string;
  style?: CSSProperties;
  /** The row's place in the list's grid (1-based, group titles counted), for a screen reader: only
   * the rows in view are in the document. None: a row outside a list (the Inbox detail's thread). */
  rowIndex?: number;
  /** The list's handlers, called with the row's item id: the same functions for every row. */
  onSelect: (id: string) => void;
  onOpen: (id: string) => void;
  compact?: boolean;
}

const revealOnSelect = (node: HTMLDivElement | null) => node?.scrollIntoView?.({ block: "nearest" });

/**
 *     ● ⌘ Finished: updated FeedModel.swift and 3 tests                 3m
 *         Ran swift test --filter FeedModelTests: 42 passed.
 *         Claude Code · api-server › Fix login redirect · ×2
 */
export const FeedRow = memo(function FeedRow({
  line,
  strings,
  time,
  style,
  rowIndex,
  onSelect,
  onOpen,
  compact = false,
}: RowProps) {
  const item = line.entry.item;
  const { row } = item;
  const meta = metaLine(item, line.threadCount, strings);
  const unread = isUnread(item);
  const detail = compact ? undefined : row.detail;
  const label = [row.who, row.where].filter(Boolean).join(", ");
  return (
    <div
      // A grid row with one cell: Up/Down move between rows, Return opens (the grid takes the keys).
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a fixed-height or virtualized row, not a table row
      role="row"
      tabIndex={-1}
      id={`feed-row-${line.id}`}
      aria-rowindex={rowIndex}
      aria-selected={line.selected}
      aria-label={[
        label ? `${label}: ${row.headline}` : row.headline,
        detail,
        fullDate(item.created_at, strings.language),
      ]
        .filter(Boolean)
        .join(". ")}
      className={cx("feed-row", line.selected && "selected", line.pending && "pending")}
      data-unread={unread ? "" : undefined}
      data-open={isOpenRequest(item) ? "" : undefined}
      data-detail={detail ? "" : undefined}
      style={style}
      ref={line.selected && !style ? revealOnSelect : undefined}
      onClick={() => onSelect(item.id)}
      onDoubleClick={() => onOpen(item.id)}
      onKeyDown={(event) => {
        if (event.key !== "Enter" || !plain(event)) return;
        event.preventDefault();
        event.stopPropagation();
        onOpen(item.id);
      }}
    >
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the row's one cell, laid on its grid */}
      <span className="feed-row-cell" role="gridcell">
        <UnreadDot visible={unread} />
        <Glyph item={item} />
        <span className="feed-row-headline">{row.headline}</span>
        {/* tooltip-allow: the shown time is relative; the tooltip is the one place its date shows. */}
        <time className="feed-row-time feed-num" title={fullDate(item.created_at, strings.language)}>
          {time}
        </time>
        {detail ? <span className={cx("feed-row-detail", row.detail_is_code && "code")}>{detail}</span> : null}
        <span className="feed-row-meta">
          <span className="feed-row-meta-text">{meta}</span>
          {row.local ? (
            <span className="feed-local" title={strings.t("item.thisMac")}>
              <FeedIcon name="machine.local" size={12} />
            </span>
          ) : null}
        </span>
      </span>
    </div>
  );
}, sameRow);

/** A row draws the same: the same line (the owner sends every item again on each change, so its
 * item is compared by content), time, handlers and place. */
function sameRow(a: RowProps, b: RowProps): boolean {
  return (
    a.strings === b.strings &&
    a.time === b.time &&
    a.compact === b.compact &&
    a.onSelect === b.onSelect &&
    a.onOpen === b.onOpen &&
    sameStyle(a.style, b.style) &&
    a.rowIndex === b.rowIndex &&
    sameLine(a.line, b.line)
  );
}

function sameLine(a: RowProps["line"], b: RowProps["line"]): boolean {
  return (
    a === b ||
    (a.id === b.id &&
      a.selected === b.selected &&
      a.pending === b.pending &&
      a.threadCount === b.threadCount &&
      sameJson(a.entry.item, b.entry.item))
  );
}

/** A virtual list's row style is a new object each render; the same values place the row the same. */
function sameStyle(a: CSSProperties | undefined, b: CSSProperties | undefined): boolean {
  if (a === b) return true;
  if (!a || !b) return false;
  const keys = Object.keys(a) as Array<keyof CSSProperties>;
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => a[key] === b[key]);
}

export const GroupHeader = memo(function GroupHeader({
  title,
  count,
  style,
  rowIndex,
}: {
  title: string;
  count: number;
  style?: CSSProperties;
  rowIndex?: number;
}) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a group title row inside the grid
    <div className="feed-group-header" role="row" aria-label={title} aria-rowindex={rowIndex} style={style}>
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the title row's one cell */}
      <span className="feed-group-cell" role="rowheader">
        <span className="feed-group-title">{title}</span>
        <span className="feed-group-count feed-num">{count}</span>
      </span>
    </div>
  );
});

// MARK: - The list

export interface LinesProps {
  lines: readonly FeedLine[];
  strings: Strings;
  now: number;
  label: string;
  compact?: boolean;
  /** The scroller the list sits in (cards above it); none: the list scrolls itself. */
  scrollParent?: string;
  /** Called with the row's item id; pass the same functions each render (context.ts `rowActions`). */
  onSelect: (id: string) => void;
  onOpen: (id: string) => void;
  onKeyDown: (event: KeyboardEvent) => void;
}

/** Rows and group titles at fixed heights, at any length only the rows near the viewport (and the
 * selected row, so Up and Down and `aria-selected` always find it) are in the document: a feed costs
 * what the window shows. Each row carries its place (`aria-rowindex`) for a screen reader. Find (Cmd-F)
 * is the filter, which the daemon runs over the whole feed (main.tsx), and the rows are not selectable
 * (desktop.css), so neither depends on which rows are in the document. */
export function FeedLines({
  lines,
  strings,
  now,
  label,
  compact,
  scrollParent,
  onSelect,
  onOpen,
  onKeyDown,
}: LinesProps) {
  const draw = (index: number, style: CSSProperties) => {
    const line = lines[index]!;
    return line.type === "header" ? (
      <GroupHeader key={line.id} title={line.title} count={line.count} style={style} rowIndex={index + 1} />
    ) : (
      <FeedRow
        key={line.id}
        line={line}
        strings={strings}
        time={relativeTime(line.entry.item.created_at, now, strings.language)}
        style={style}
        rowIndex={index + 1}
        compact={compact}
        onSelect={onSelect}
        onOpen={onOpen}
      />
    );
  };
  const active = lines.findIndex((line) => line.type === "row" && line.selected);
  return (
    // The virtual list is the grid; this wrapper is its tab stop and takes its keys.
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/no-noninteractive-tabindex
    <div className="feed-lines" tabIndex={0} onKeyDown={onKeyDown}>
      <VirtualList
        className="feed-lines-virtual"
        count={lines.length}
        estimateSize={(index) => (compact && lines[index]!.type === "row" ? 48 : lineHeight(lines[index]!))}
        activeIndex={active >= 0 ? active : undefined}
        renderRow={draw}
        label={label}
        role="grid"
        scrollParent={scrollParent}
      />
    </div>
  );
}

// MARK: - A request's content

/** A command in a faint monospaced block, with its working directory. */
function CodeBlock({ text, caption }: { text: string; caption?: string }) {
  return (
    <div className="feed-code">
      <code className="feed-code-text">{text}</code>
      {caption ? <span className="feed-code-caption">{caption}</span> : null}
    </div>
  );
}

function lineTone(line: string): string | undefined {
  if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@")) return "meta";
  if (line.startsWith("+")) return "added";
  if (line.startsWith("-")) return "removed";
  return undefined;
}

/** A plain unified diff: added lines green, removed lines red, hunks dim. With `maxLines` (a row's
 *  preview) its first lines; without (the Inbox detail) every line, of which only those near the
 *  viewport mount (DiffLines.tsx): an attachment's diff has no length cap. */
export function DiffPreview({ attachment, maxLines }: { attachment: FeedAttachment; maxLines?: number }) {
  const lines = useMemo(() => (attachment.text ?? "").split("\n"), [attachment.text]);
  return (
    <div className="feed-diff">
      <span className="feed-diff-name">
        <FeedIcon name="file.text" size={12} />
        {attachment.name}
      </span>
      {maxLines === undefined ? (
        <DiffLines key={attachment.id} lines={lines} tone={lineTone} />
      ) : (
        <div className="feed-diff-lines">
          {lines.slice(0, maxLines).map((line, index) => (
            // oxlint-disable-next-line react/no-array-index-key -- diff lines repeat; their order is their identity
            <span key={index} className="feed-diff-line" data-tone={lineTone(line)}>
              {shownLine(line)}
            </span>
          ))}
          {maxLines < lines.length ? (
            <span className="feed-diff-line" data-tone="meta">
              …
            </span>
          ) : null}
        </div>
      )}
    </div>
  );
}

function Origin({ host, reason }: { host: string; reason?: string }) {
  return (
    <div className="feed-origin">
      <span className="feed-origin-host">
        <FeedIcon name="security.lock" size={12} />
        {host.replace("https://", "")}
      </span>
      {reason ? <span className="feed-origin-reason">{reason}</span> : null}
    </div>
  );
}

/** What a request asks, above its controls. `full` shows everything (the Inbox detail). */
export function PromptSummary({ item, full = false }: { item: ViewItem; full?: boolean }) {
  const p = item.prompt ?? {};
  const diff = diffAttachment(item);
  let prompt: ReactNode = null;
  switch (item.kind) {
    case "approve":
      if (p.action?.command) prompt = <CodeBlock text={p.action.command} caption={p.action.cwd} />;
      break;
    case "question":
      if (p.question) prompt = <p className="feed-prompt-text">{p.question}</p>;
      break;
    case "confirm":
      if (p.statement) prompt = <p className="feed-prompt-text">{p.statement}</p>;
      break;
    case "sign-in":
      prompt = <Origin host={p.origin ?? ""} reason={p.reason} />;
      break;
    case "passkey":
      prompt = <Origin host={p.rp_id ?? p.origin ?? ""} reason={p.reason} />;
      break;
    case "review":
      if (full && p.checklist?.length)
        prompt = (
          <ul className="feed-checklist">
            {p.checklist.map((line) => (
              <li key={line}>
                <FeedIcon name="list.bullet.item" size={12} />
                {line}
              </li>
            ))}
          </ul>
        );
      break;
    case "handoff":
      if (full && p.resume_hint) prompt = <p className="feed-prompt-text">{p.resume_hint}</p>;
      break;
    case "file":
      if (p.purpose) prompt = <p className="feed-prompt-text">{p.purpose}</p>;
      break;
  }
  const body = item.body && (full || isRequest(item)) ? item.body : "";
  if (!body && !prompt && !diff) return null;
  return (
    <div className="feed-summary">
      {body ? <p className={cx("feed-body", !full && "clamped")}>{body}</p> : null}
      {prompt}
      {diff ? <DiffPreview attachment={diff} maxLines={full ? undefined : 6} /> : null}
    </div>
  );
}

/** Its answer controls' part of the snapshot (context.ts `answerState`), and what the card draws. */
export interface RequestCardProps extends AnswerState {
  item: ViewItem;
  store: FeedStore;
  strings: Strings;
  /** `relativeTime` of the item at the page's clock. */
  time: string;
}

/** An open request in the list: what it asks and how to answer, inline. It gets its own part of the
 * snapshot only, so a change to another item, a draft in another card or the selection renders it not. */
export const RequestCard = memo(function RequestCard({
  item,
  store,
  strings,
  time,
  pending,
  ...answer
}: RequestCardProps) {
  return (
    <div className={cx("feed-card", pending && "pending")} data-item={item.id}>
      <div className="feed-card-head">
        <Glyph item={item} />
        <div className="feed-card-titles">
          <span className="feed-card-title">{item.title}</span>
          <PosterLine item={item} strings={strings} time={time} />
        </div>
      </div>
      <div className="feed-card-body">
        <PromptSummary item={item} />
        <AnswerControls item={item} store={store} strings={strings} density="inline" pending={pending} {...answer} />
      </div>
    </div>
  );
}, sameCard);

function sameCard(a: RequestCardProps, b: RequestCardProps): boolean {
  for (const key in a) {
    if (key === "item") continue;
    if (!Object.is(a[key as keyof RequestCardProps], b[key as keyof RequestCardProps])) return false;
  }
  return Object.keys(a).length === Object.keys(b).length && sameJson(a.item, b.item);
}
