// The message timeline: a virtual window of rows (useTimelineWindow renders only the rows near the
// viewport, measured after render because messages differ in height), day lines with a centered
// date pill, message rows and the running reply. Scrolling near the top asks the store for one
// older page.
import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { DraftRow, MessageRow } from "./MessageRow";
import type { TimelineRow } from "./model";
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
  className?: string;
  /** What the empty timeline says. */
  empty?: string;
}

const estimate = (row: TimelineRow) =>
  row.kind === "day" || row.kind === "replies" ? 44 : row.kind === "new" ? 24 : row.head ? 64 : 28;

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
  className,
  empty,
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
  const { items, total, scroller, measure, onScroll } = useTimelineWindow(sized, conversation);
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
