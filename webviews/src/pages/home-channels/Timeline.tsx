// The message timeline: a virtual window of rows (useTimelineWindow renders only the rows near the
// viewport, measured after render because messages differ in height), day lines with a centered
// date pill, message rows and the running reply. Scrolling near the top asks the store for one
// older page.
import { useMemo, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { HomeIcon } from "./icons";
import { DraftRow, MessageRow, PendingRow } from "./MessageRow";
import type { TimelineRow } from "./model";
import type { ThreadMeta } from "./threads";
import type { HomeMessage, HomeParticipant } from "./types";
import { useTimelineWindow } from "./useTimelineWindow";

export interface TimelineProps {
  conversation?: string;
  rows: TimelineRow[];
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  strings: Strings;
  loadingOlder: boolean;
  /** The message whose inline editor is open. */
  editing?: string;
  onLoadOlder(): void;
  onOpenThread?(root: string): void;
  onReact(message: HomeMessage, value: string): void;
  onEditStart?(message: HomeMessage): void;
  onEditEnd?(): void;
  onEdit?(message: HomeMessage, text: string): Promise<boolean>;
  onRetract?(message: HomeMessage): void;
  onReply?(message: HomeMessage): void;
  onCopyLink?(message: HomeMessage): void;
  /** The message a link opened. */
  highlight?: string;
  className?: string;
  /** What the empty timeline says. */
  empty?: ReactNode;
  /** The message under the keyboard cursor (kept in view). */
  selected?: string;
  /** The thread object of a root (title, status, owner). */
  meta?(root: HomeMessage): ThreadMeta | undefined;
  /** The root whose thread is open in place. */
  expanded?: string;
  onAnswer?(message: HomeMessage, partIndex: number, selections: Record<string, string>): void;
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  /** An open thread's actions: reply, focus it, resolve or reopen it, close it, load more replies. */
  onThreadAction?(root: string, action: ThreadAction): void;
  /** The focused thread draws its end row without the Focus and Hide actions. */
  focused?: boolean;
}

export type ThreadAction = "reply" | "focus" | "resolve" | "close" | "more";

const estimate = (row: TimelineRow) =>
  row.kind === "day" || row.kind === "replies" || row.kind === "threadEnd"
    ? 44
    : row.kind === "new"
      ? 24
      : row.head
        ? 64
        : 28;

export function Timeline({
  conversation,
  rows,
  people,
  me,
  strings,
  loadingOlder,
  editing,
  onLoadOlder,
  onOpenThread,
  onReact,
  onEditStart,
  onEditEnd,
  onEdit,
  onRetract,
  onReply,
  onCopyLink,
  highlight,
  className,
  empty,
  selected,
  meta,
  expanded,
  onAnswer,
  onRetry,
  onDiscard,
  onThreadAction,
  focused = false,
}: TimelineProps) {
  const timeFormat = useMemo(
    () => new Intl.DateTimeFormat(strings.language, { hour: "numeric", minute: "2-digit" }),
    [strings.language],
  );
  const dayFormat = useMemo(
    () => new Intl.DateTimeFormat(strings.language, { weekday: "long", month: "long", day: "numeric" }),
    [strings.language],
  );
  const sized = useMemo(() => rows.map((row) => ({ key: row.key, estimate: estimate(row) })), [rows]);
  // Destructured: `scroller` alone is the ref; the rest are plain render values.
  const { items, total, scroller, measure, onScroll } = useTimelineWindow(sized, conversation, highlight, selected);
  if (rows.length === 0)
    return <div className={`hc-timeline-empty ${className ?? ""}`}>{empty ?? strings.t("timeline.empty")}</div>;
  return (
    <div className={`hc-timeline-frame ${className ?? ""}`}>
      {loadingOlder && <div className="hc-older">{strings.t("timeline.loadingOlder")}</div>}
      <div
        ref={scroller}
        className="hc-timeline"
        onScroll={() => {
          if (onScroll()) onLoadOlder();
        }}
        role="log"
        aria-live="polite"
      >
        <div className="hc-timeline-space" style={{ height: total }}>
          {items.map((item) => {
            const row = rows[item.index]!;
            return (
              <div
                key={item.key}
                data-key={item.key}
                ref={measure}
                className="hc-timeline-row"
                style={{ transform: `translateY(${item.start}px)` }}
              >
                {row.kind === "day" ? (
                  <div className="hc-day">
                    <span className="hc-day-pill">{dayLabel(row.at, strings, dayFormat)}</span>
                  </div>
                ) : row.kind === "new" ? (
                  <div className="hc-new-line">
                    <span>{strings.t("timeline.new")}</span>
                  </div>
                ) : row.kind === "replies" ? (
                  <div className="hc-replies-line">
                    <span>
                      {row.count === 1
                        ? strings.t("thread.replies.one")
                        : strings.format("thread.replies.many", String(row.count))}
                    </span>
                  </div>
                ) : row.kind === "pending" ? (
                  <PendingRow
                    pending={row.pending}
                    head={row.head}
                    depth={row.depth}
                    me={me ? people.get(me) : undefined}
                    strings={strings}
                    onRetry={(key) => onRetry?.(key)}
                    onDiscard={(key) => onDiscard?.(key)}
                  />
                ) : row.kind === "threadEnd" ? (
                  <ThreadEnd
                    count={row.count}
                    more={row.more}
                    resolved={metaById(rows, row.root, meta)?.status === "resolved"}
                    focused={focused}
                    strings={strings}
                    onAction={(action) => onThreadAction?.(row.root, action)}
                  />
                ) : row.kind === "draft" ? (
                  <DraftRow draft={row.draft} head={row.head} people={people} strings={strings} />
                ) : (
                  <MessageRow
                    message={row.message}
                    head={row.head}
                    thread={row.thread}
                    people={people}
                    me={me}
                    strings={strings}
                    timeFormat={timeFormat}
                    editing={row.message.id === editing}
                    onOpenThread={onOpenThread}
                    onReact={onReact}
                    onEditStart={onEditStart}
                    onEditEnd={onEditEnd}
                    onEdit={onEdit}
                    onRetract={onRetract}
                    onReply={onReply}
                    onCopyLink={onCopyLink}
                    depth={row.depth}
                    parent={row.parent}
                    highlighted={row.message.id === highlight}
                    selected={row.message.id === selected}
                    meta={row.thread ? meta?.(row.message) : undefined}
                    expanded={row.message.id === expanded}
                    onAnswer={onAnswer}
                  />
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/** The thread object of a root among the rows. */
function metaById(
  rows: readonly TimelineRow[],
  root: string,
  meta: TimelineProps["meta"],
): ThreadMeta | undefined {
  const row = rows.find((entry) => entry.kind === "message" && entry.message.id === root);
  return row?.kind === "message" && meta ? meta(row.message) : undefined;
}

/** The end of a thread open in place: Reply, Resolve, Focus and Hide as quiet words with their keys. */
function ThreadEnd({
  count,
  more,
  resolved,
  focused,
  strings,
  onAction,
}: {
  count: number;
  more: boolean;
  resolved: boolean;
  focused: boolean;
  strings: Strings;
  onAction(action: ThreadAction): void;
}) {
  const { t } = strings;
  return (
    <div className={`hc-thread-end${focused ? " focused" : ""}`} role="toolbar" aria-label={t("thread.title")}>
      {more && (
        <button type="button" className="hc-end-button" onClick={() => onAction("more")}>
          {t("thread.more")}
        </button>
      )}
      <button type="button" className="hc-end-button strong" onClick={() => onAction("reply")}>
        <HomeIcon name="reply" size={15} />
        {t("action.replyTo")}
        <kbd>R</kbd>
      </button>
      <button type="button" className="hc-end-button" onClick={() => onAction("resolve")}>
        <HomeIcon name="check" size={15} />
        {t(resolved ? "thread.reopen" : "thread.resolve")}
        <kbd>E</kbd>
      </button>
      {!focused && (
        <button type="button" className="hc-end-button" onClick={() => onAction("focus")}>
          <HomeIcon name="expand" size={14} />
          {t("thread.focus")}
        </button>
      )}
      {!focused && (
        <button type="button" className="hc-end-button" onClick={() => onAction("close")}>
          {t("thread.collapse")}
          <kbd>T</kbd>
        </button>
      )}
      <span className="hc-end-count">
        {count === 1 ? t("thread.replies.one") : strings.format("thread.replies.many", String(count))}
      </span>
    </div>
  );
}

function dayLabel(at: number, strings: Strings, format: Intl.DateTimeFormat): string {
  const day = new Date(at);
  const today = new Date();
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  const same = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  if (same(day, today)) return strings.t("day.today");
  if (same(day, yesterday)) return strings.t("day.yesterday");
  return format.format(day);
}
