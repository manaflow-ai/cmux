// The Feed's shared pieces: a row (FeedRowCells), its glyph and poster line (FeedGlyph), the empty
// state, the disconnected banner (FeedView), a request card (FeedListView's FeedRequestCard), the
// prompt summary (FeedPromptSummary) and the list that virtualizes past 200 rows (FeedRowsView).
import type { CSSProperties, KeyboardEvent, ReactNode } from "react";
import { cx } from "../../ui/cx";
import type { Strings } from "../shared/i18n";
import { VirtualList } from "../../ui/VirtualList";
import { AnswerControls } from "./AnswerControls";
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
  VIRTUALIZE_AFTER,
  type FeedLine,
} from "./model";
import { isPending, plain, type FeedProps } from "./context";
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

/** "Claude Code · api-server · 3m", the local mark, "×2" (PosterLine). */
export function PosterLine({ item, strings, now }: { item: ViewItem; strings: Strings; now: number }) {
  return (
    <span className="feed-poster">
      <span className="feed-poster-label">{posterLabel(item)}</span>
      <span aria-hidden="true">·</span>
      <time className="feed-num" title={fullDate(item.created_at, strings.language)}>
        {relativeTime(item.created_at, now, strings.language)}
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

/** A line above the content: the owner is unreachable. */
export function Banner({ text }: { text: string }) {
  return (
    <output className="feed-banner">
      <span className="feed-banner-dot" aria-hidden="true" />
      {text}
    </output>
  );
}

// MARK: - A row

export interface RowProps {
  line: Extract<FeedLine, { type: "row" }>;
  strings: Strings;
  now: number;
  style?: CSSProperties;
  onSelect: () => void;
  onOpen: () => void;
  compact?: boolean;
}

const revealOnSelect = (node: HTMLDivElement | null) => node?.scrollIntoView?.({ block: "nearest" });

/**
 *     ● ⌘ Finished: updated FeedModel.swift and 3 tests                 3m
 *         Ran swift test --filter FeedModelTests: 42 passed.
 *         Claude Code · api-server › Fix login redirect · ×2
 */
export function FeedRow({ line, strings, now, style, onSelect, onOpen, compact = false }: RowProps) {
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
      title={row.headline}
      onClick={onSelect}
      onDoubleClick={onOpen}
      onKeyDown={(event) => {
        if (event.key !== "Enter" || !plain(event)) return;
        event.preventDefault();
        event.stopPropagation();
        onOpen();
      }}
    >
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the row's one cell, laid on its grid */}
      <span className="feed-row-cell" role="gridcell">
        <UnreadDot visible={unread} />
        <Glyph item={item} />
        <span className="feed-row-headline">{row.headline}</span>
        <time className="feed-row-time feed-num" title={fullDate(item.created_at, strings.language)}>
          {relativeTime(item.created_at, now, strings.language)}
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
}

export function GroupHeader({ title, count, style }: { title: string; count: number; style?: CSSProperties }) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a group title row inside the grid
    <div className="feed-group-header" role="row" aria-label={title} style={style}>
      {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the title row's one cell */}
      <span className="feed-group-cell" role="rowheader">
        <span className="feed-group-title">{title}</span>
        <span className="feed-group-count feed-num">{count}</span>
      </span>
    </div>
  );
}

// MARK: - The list

export interface LinesProps {
  lines: readonly FeedLine[];
  strings: Strings;
  now: number;
  label: string;
  compact?: boolean;
  /** The scroller the list sits in (cards above it); none: the list scrolls itself. */
  scrollParent?: string;
  onSelect: (id: string) => void;
  onOpen: (id: string) => void;
  onKeyDown: (event: KeyboardEvent) => void;
}

/** Rows and group titles at fixed heights; past VIRTUALIZE_AFTER lines only the rows near the
 * viewport are in the document, so a long feed costs what the window shows. */
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
  const draw = (line: FeedLine, style?: CSSProperties) =>
    line.type === "header" ? (
      <GroupHeader key={line.id} title={line.title} count={line.count} style={style} />
    ) : (
      <FeedRow
        key={line.id}
        line={line}
        strings={strings}
        now={now}
        style={style}
        compact={compact}
        onSelect={() => onSelect(line.entry.item.id)}
        onOpen={() => onOpen(line.entry.item.id)}
      />
    );
  const active = lines.findIndex((line) => line.type === "row" && line.selected);
  if (lines.length > VIRTUALIZE_AFTER) {
    return (
      // The virtual list is the grid; this wrapper is its tab stop and takes its keys.
      // oxlint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/no-noninteractive-tabindex
      <div className="feed-lines" tabIndex={0} onKeyDown={onKeyDown}>
        <VirtualList
          className="feed-lines-virtual"
          count={lines.length}
          estimateSize={(index) => (compact && lines[index]!.type === "row" ? 48 : lineHeight(lines[index]!))}
          activeIndex={active >= 0 ? active : undefined}
          renderRow={(index, style) => draw(lines[index]!, style)}
          label={label}
          role="grid"
          scrollParent={scrollParent}
        />
      </div>
    );
  }
  return (
    <div className="feed-lines" role="grid" aria-label={label} tabIndex={0} onKeyDown={onKeyDown}>
      {lines.map((line) => draw(line))}
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

/** A plain unified diff: added lines green, removed lines red, hunks dim. */
export function DiffPreview({ attachment, maxLines }: { attachment: FeedAttachment; maxLines?: number }) {
  const lines = (attachment.text ?? "").split("\n");
  const shown = maxLines === undefined ? lines : lines.slice(0, maxLines);
  return (
    <div className="feed-diff">
      <span className="feed-diff-name">
        <FeedIcon name="file.text" size={12} />
        {attachment.name}
      </span>
      <div className="feed-diff-lines">
        {shown.map((line, index) => (
          // oxlint-disable-next-line react/no-array-index-key -- diff lines repeat; their order is their identity
          <span key={index} className="feed-diff-line" data-tone={lineTone(line)}>
            {line || " "}
          </span>
        ))}
        {shown.length < lines.length ? (
          <span className="feed-diff-line" data-tone="meta">
            …
          </span>
        ) : null}
      </div>
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

/** An open request in the list: what it asks and how to answer, inline. */
export function RequestCard({ item, store, snap, strings }: FeedProps & { item: ViewItem }) {
  return (
    <div className={cx("feed-card", isPending(snap, item) && "pending")} data-item={item.id}>
      <div className="feed-card-head">
        <Glyph item={item} />
        <div className="feed-card-titles">
          <span className="feed-card-title">{item.title}</span>
          <PosterLine item={item} strings={strings} now={snap.now} />
        </div>
      </div>
      <div className="feed-card-body">
        <PromptSummary item={item} />
        <AnswerControls item={item} store={store} snap={snap} strings={strings} density="inline" />
      </div>
    </div>
  );
}
