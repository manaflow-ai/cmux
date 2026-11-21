// Waiting on me, on a new chat's home: one swimlane per agent chat active today, its time drawn as
// working, waiting on the person (red) or idle (empty), under one line that says how long agents
// waited on the person in all. A red stretch is a button: it opens its chat at the turn it began
// in. Only the rows in the scroll window are mounted, and a lane draws at most a few hundred
// rectangles whatever its day held (waitingModel.ts `layLane`), so the cost stays the same with 50
// chats or 500 status changes. Nothing here animates.
import { type CSSProperties, useState } from "react";

import { currentLanguage, useT } from "../i18n";
import { type ReadWaitingDay, useWaitingDay } from "./useWaitingDay";
import { type AcpmuxSessionEntry, sessionTitle } from "../sessionList";
import {
  clockTime,
  dayWindow,
  formatWaited,
  hourLabel,
  hourTicks,
  type LaidSpan,
  layLane,
  statusKey,
  visibleRows,
  type WaitingDay,
  type WaitingLane,
} from "./waitingModel";
import "./waiting.css";

/// How the lanes draw. `bars`: a title column beside each lane's bar and its waited time (the
/// home's). `ribbon`: the title over a thin ribbon, for a narrow pane. `heat`: working time faint,
/// so only the waits stand out. The gallery shows all three.
export type WaitingLook = "bars" | "ribbon" | "heat";

const ROW_HEIGHT: Record<WaitingLook, number> = { bars: 24, ribbon: 32, heat: 24 };
/** Rows shown before the lanes scroll. */
export const VISIBLE_ROWS = 6;

type Shown = { lane: WaitingLane; title: string };

/// The home's section: mounted while the home shows, it reads the day (useWaitingDay.ts) and asks
/// again when a chat's status changes.
export function HomeWaitingTimeline({
  read,
  sessions,
  linked,
  onJump,
}: {
  read: ReadWaitingDay;
  sessions: readonly AcpmuxSessionEntry[];
  /// The pane's link to acpmux is up (model.ts `linkUp`): a read waits for it.
  linked: boolean;
  onJump: (sessionId: string, turnId?: string) => void;
}) {
  const day = useWaitingDay(read, statusKey(sessions), true, linked);
  return <WaitingTimeline day={day} sessions={sessions} onJump={onJump} />;
}

export function WaitingTimeline({
  day,
  sessions,
  onJump,
  look = "bars",
}: {
  day: WaitingDay | undefined;
  /// The pane's chats: a lane is drawn only for a chat in this list, under its title.
  sessions: readonly AcpmuxSessionEntry[];
  /// Opens `sessionId`, at `turnId` when the wait's turn is known.
  onJump: (sessionId: string, turnId?: string) => void;
  look?: WaitingLook;
}) {
  const t = useT();
  const [scrollTop, setScrollTop] = useState(0);
  if (!day) return null;
  const byId = new Map(sessions.map((session) => [session.sessionId, session]));
  const shown: Shown[] = [];
  for (const lane of day.lanes) {
    const session = byId.get(lane.sessionId);
    if (session) shown.push({ lane, title: sessionTitle(session, t) });
  }
  if (shown.length === 0) return null;
  const language = currentLanguage() || undefined;
  const { from, to } = dayWindow(day);
  const ticks = hourTicks(from, to);
  const rowHeight = ROW_HEIGHT[look];
  const viewport = Math.min(shown.length, VISIBLE_ROWS) * rowHeight;
  const { first, last } = visibleRows(scrollTop, viewport, rowHeight, shown.length);
  const waited = day.blockedMs > 0;
  const style = {
    "--waiting-row": `${rowHeight}px`,
    "--waiting-viewport": `${viewport}px`,
    "--waiting-rows": `${shown.length * rowHeight}px`,
  } as CSSProperties;
  return (
    <section className="acpmux-waiting" data-look={look} aria-label={t("waiting.section")} style={style}>
      <header className="acpmux-waiting-head">
        <p className="acpmux-waiting-total" data-waited={waited || undefined}>
          {waited ? t("waiting.total", { duration: formatWaited(day.blockedMs, t) }) : t("waiting.none")}
        </p>
        <span className="acpmux-waiting-legend" aria-hidden="true">
          <i data-state="working" />
          {t("waiting.legend.working")}
          <i data-state="blocked" />
          {t("waiting.legend.blocked")}
        </span>
      </header>
      <div className="acpmux-waiting-scroll" onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}>
        <div className="acpmux-waiting-rows">
          {shown.slice(first, last + 1).map(({ lane, title }, offset) => (
            <Lane
              key={lane.sessionId}
              index={first + offset}
              lane={lane}
              title={title}
              look={look}
              from={from}
              to={to}
              ticks={ticks}
              language={language}
              onJump={onJump}
            />
          ))}
        </div>
      </div>
      <div className="acpmux-waiting-axis" aria-hidden="true">
        <span className="acpmux-waiting-axis-track">
          {ticks
            .filter((tick) => tick.labeled && tick.left < 0.94)
            .map((tick) => (
              <span key={tick.at} style={{ "--waiting-left": tick.left } as CSSProperties}>
                {hourLabel(tick.at, language)}
              </span>
            ))}
          <span className="acpmux-waiting-now-label">{t("waiting.now")}</span>
        </span>
      </div>
    </section>
  );
}

function Lane({
  index,
  lane,
  title,
  look,
  from,
  to,
  ticks,
  language,
  onJump,
}: {
  index: number;
  lane: WaitingLane;
  title: string;
  look: WaitingLook;
  from: number;
  to: number;
  ticks: readonly { at: number; left: number }[];
  language?: string;
  onJump: (sessionId: string, turnId?: string) => void;
}) {
  const t = useT();
  const laid = layLane(lane.spans, from, to);
  const place = (rect: LaidSpan) => ({ "--waiting-left": rect.left, "--waiting-width": rect.width }) as CSSProperties;
  const label = (rect: LaidSpan) =>
    t(rect.state === "blocked" ? "waiting.span.blocked" : "waiting.span.working", {
      duration: formatWaited(rect.ms, t),
      time: clockTime(rect.start, language),
    });
  return (
    <div className="acpmux-waiting-row" style={{ "--waiting-index": index } as CSSProperties}>
      <span className="acpmux-waiting-title" title={title}>
        {title}
      </span>
      <span className="acpmux-waiting-track">
        {ticks.map((tick) => (
          <i key={tick.at} className="acpmux-waiting-tick" style={{ "--waiting-left": tick.left } as CSSProperties} />
        ))}
        {laid.map((rect) =>
          rect.state === "blocked" ? (
            <button
              key={`b${rect.start}`}
              type="button"
              className="acpmux-waiting-span"
              data-state="blocked"
              style={place(rect)}
              title={label(rect)}
              aria-label={`${title}: ${label(rect)}`}
              onClick={() => onJump(lane.sessionId, rect.turnId)}
            />
          ) : (
            <span
              key={`w${rect.start}`}
              className="acpmux-waiting-span"
              data-state="working"
              style={place(rect)}
              title={label(rect)}
            />
          ),
        )}
        <i className="acpmux-waiting-now" />
      </span>
      {look !== "ribbon" && (
        <span className="acpmux-waiting-lane-total" data-waited={lane.blockedMs >= 60_000 || undefined}>
          {lane.blockedMs >= 60_000 ? formatWaited(lane.blockedMs, t) : ""}
        </span>
      )}
    </div>
  );
}
