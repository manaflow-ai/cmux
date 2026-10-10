// The message timeline: a virtualized window of compact rows (only the rows near the viewport are
// in the DOM), measured after render because messages differ in height. Scrolling near the top
// asks the store for one older page.
import { useMemo, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { Strings } from "../shared/i18n";
import { MessageRow } from "./MessageRow";
import type { TimelineRow } from "./model";
import type { HomeMessage, HomeParticipant } from "./types";
import { useStickToBottom } from "./useStickToBottom";

export interface TimelineProps {
  conversation?: string;
  rows: TimelineRow[];
  people: ReadonlyMap<string, HomeParticipant>;
  me?: string;
  strings: Strings;
  loadingOlder: boolean;
  onLoadOlder(): void;
  onOpenThread?(root: string): void;
  onReact(message: HomeMessage, value: string): void;
  className?: string;
}

export function Timeline({
  conversation,
  rows,
  people,
  me,
  strings,
  loadingOlder,
  onLoadOlder,
  onOpenThread,
  onReact,
  className,
}: TimelineProps) {
  const scroller = useRef<HTMLDivElement | null>(null);
  const timeFormat = useMemo(
    () => new Intl.DateTimeFormat(strings.language, { hour: "numeric", minute: "2-digit" }),
    [strings.language],
  );
  const dayFormat = useMemo(
    () => new Intl.DateTimeFormat(strings.language, { weekday: "long", month: "long", day: "numeric" }),
    [strings.language],
  );
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scroller.current,
    estimateSize: (index) =>
      rows[index]?.kind === "day" ? 32 : rows[index]?.kind === "message" && rows[index].head ? 52 : 24,
    getItemKey: (index) => rows[index]?.key ?? index,
    overscan: 8,
  });
  const firstMessage = rows.find((row) => row.kind === "message")?.key;
  const stick = useStickToBottom(virtualizer, scroller, conversation, rows.length, firstMessage);
  const onScroll = () => {
    if (stick.onScroll()) onLoadOlder();
  };
  if (rows.length === 0)
    return <div className={`hc-timeline-empty ${className ?? ""}`}>{strings.t("timeline.empty")}</div>;
  return (
    <div className={`hc-timeline-frame ${className ?? ""}`}>
      {loadingOlder && <div className="hc-older">{strings.t("timeline.loadingOlder")}</div>}
      <div ref={scroller} className="hc-timeline" onScroll={onScroll} role="log" aria-live="polite">
        <div className="hc-timeline-space" style={{ height: virtualizer.getTotalSize() }}>
          {virtualizer.getVirtualItems().map((item) => {
            const row = rows[item.index]!;
            return (
              <div
                key={item.key}
                data-index={item.index}
                ref={virtualizer.measureElement}
                className="hc-timeline-row"
                style={{ transform: `translateY(${item.start}px)` }}
              >
                {row.kind === "day" ? (
                  <div className="hc-day" role="separator">
                    <span>{dayLabel(row.at, strings, dayFormat)}</span>
                  </div>
                ) : (
                  <MessageRow
                    message={row.message}
                    head={row.head}
                    thread={row.thread}
                    author={people.get(row.message.author)}
                    me={me}
                    strings={strings}
                    timeFormat={timeFormat}
                    onOpenThread={onOpenThread}
                    onReact={onReact}
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
