// Timeline: today across every agent, newest first, as one scrolling feed: an agent started,
// started waiting on you, failed or finished; a pull request was opened or merged. The app's Feed
// draws native cards only (CmuxNextFeed), so this feed has its own small card.
import { memo, useMemo } from "react";
import { sameRowProps, timeline, type TimelineEvent, type TimelineKind } from "../model";
import { agentsOf, Loaded, machineLabel, PRChip } from "../parts";
import type { ChiefViewProps } from "../registry";
import type { StatusGlyphName } from "../../../ui/statusGlyphs.generated";
import { StatusGlyph } from "../../../ui/StatusGlyph";
import { intl } from "../../../ui/intl";

const GLYPH: Record<TimelineKind, StatusGlyphName> = {
  spawned: "working",
  waiting: "waiting",
  failed: "error",
  finished: "done",
  opened: "idle",
  merged: "done",
};

export function TimelineView({ data, strings, today, onOpenAgent, onOpenURL }: ChiefViewProps) {
  const agents = agentsOf(data);
  const landing = data.landing.status === "ready" ? data.landing.reply : undefined;
  const events = useMemo(() => timeline(agents, landing, today), [agents, landing, today]);
  const clock = useMemo(
    () => intl.DateTimeFormat(strings.language, { hour: "numeric", minute: "2-digit" }),
    [strings.language],
  );
  return (
    <Loaded status={data.agents.status} strings={strings}>
      {events.length === 0 ? (
        <p className="cv-note">{strings.t("chiefViews.timeline.empty")}</p>
      ) : (
        <ol className="cv-feed">
          {events.map((event) => (
            <EventRow
              key={event.id}
              event={event}
              clock={clock}
              strings={strings}
              onOpenAgent={onOpenAgent}
              onOpenURL={onOpenURL}
            />
          ))}
        </ol>
      )}
    </Loaded>
  );
}

/** One event; it draws again only when its agent or pull request changed (events are rebuilt from
 * the agents on each change, so the memo compares them one level in). */
const EventRow = memo(function EventRow({
  event,
  clock,
  strings,
  onOpenAgent,
  onOpenURL,
}: {
  event: TimelineEvent;
  clock: Intl.DateTimeFormat;
  strings: ChiefViewProps["strings"];
  onOpenAgent: ChiefViewProps["onOpenAgent"];
  onOpenURL: ChiefViewProps["onOpenURL"];
}) {
  const open = () => {
    if (event.agent) onOpenAgent(event.agent);
    else if (event.pr) onOpenURL(event.pr.url);
  };
  return (
    <li className="cv-event" data-kind={event.kind}>
      <button type="button" className="cv-event-button" onClick={open}>
        <time className="cv-event-time" dateTime={new Date(event.at).toISOString()}>
          {clock.format(event.at)}
        </time>
        <span className="cv-event-rail" aria-hidden="true">
          <StatusGlyph name={GLYPH[event.kind]} size={12} />
        </span>
        <span className="cv-event-body">
          <span className="cv-event-kind">{strings.t(`chiefViews.timeline.${event.kind}`)}</span>
          <span className="cv-event-title">{event.title}</span>
          {(event.detail || event.agent || event.pr) && (
            <span className="cv-event-detail">
              {event.pr && <PRChip number={event.pr.number} />}
              {event.agent && <span className="cv-row-machine">{machineLabel(event.agent, strings)}</span>}
              {event.detail && <span className="cv-event-text">{event.detail}</span>}
            </span>
          )}
        </span>
      </button>
    </li>
  );
}, sameRowProps);
