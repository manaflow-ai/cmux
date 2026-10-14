// The message timeline: a virtual window of rows (useTimelineWindow renders only the rows near the
// viewport, measured after render because messages differ in height), day lines (a label on the
// start edge and a hairline), message rows, thread rows (one titled row per thread, ThreadRow)
// and the running reply. Scrolling near the top asks the store for one older page. The keyboard's
// current message (j/k) is kept in view (useKeepInView).
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { DraftRow, MessageRow } from "./MessageRow";
import { PENDING_PREFIX, type TimelineRow } from "./model";
import type { ThreadObject } from "./threads";
import { ThreadRow } from "./ThreadRow";
import type { HomeMessage, HomeParticipant } from "./types";
import { useKeepInView } from "./useKeepInView";
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
  empty?: string;
  /** The thread object of a root: given, thread roots show as one titled row (ThreadRow). */
  threadFor?(root: HomeMessage): ThreadObject;
  /** The thread the sheet shows. */
  openThread?: string;
  /** The keyboard's current message. */
  focused?: string;
  /** A pending message's state (my send the owner has not shown yet). */
  pendingState?(key: string): "sending" | "failed" | undefined;
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  stamp?(at: number): string;
}

const estimate = (row: TimelineRow) =>
  row.kind === "day" || row.kind === "replies" ? 36 : row.kind === "new" ? 24 : row.head ? 48 : 24;

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
  threadFor,
  openThread,
  focused,
  pendingState,
  onRetry,
  onDiscard,
  stamp,
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
  const { items, total, scroller, measure, onScroll } = useTimelineWindow(sized, conversation, highlight);
  useKeepInView(scroller, focused);
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
                  <div className="lg-day">
                    <span>{dayLabel(row.at, strings, dayFormat)}</span>
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
                ) : row.kind === "draft" ? (
                  <DraftRow draft={row.draft} head={row.head} people={people} strings={strings} />
                ) : row.thread && threadFor && onOpenThread && stamp ? (
                  <ThreadRow
                    thread={threadFor(row.message)}
                    summary={row.thread}
                    people={people}
                    strings={strings}
                    stamp={stamp}
                    open={openThread === row.message.id}
                    focused={focused === row.message.id}
                    highlighted={highlight === row.message.id}
                    onOpen={() => onOpenThread(row.message.id)}
                  />
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
                    focused={row.message.id === focused}
                    {...pendingProps(row.message, pendingState, onRetry, onDiscard)}
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

function pendingProps(
  message: HomeMessage,
  state: TimelineProps["pendingState"],
  onRetry: TimelineProps["onRetry"],
  onDiscard: TimelineProps["onDiscard"],
) {
  if (!message.id.startsWith(PENDING_PREFIX) || !state) return {};
  const key = message.id.slice(PENDING_PREFIX.length);
  return {
    pending: state(key) ?? "sending",
    onRetry: () => onRetry?.(key),
    onDiscard: () => onDiscard?.(key),
  };
}
