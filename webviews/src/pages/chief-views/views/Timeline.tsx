// Timeline: today across every agent, newest first, as one scrolling feed: an agent started,
// started waiting on you, failed or finished; a pull request was opened or merged. The app's Feed
// draws native cards only (CmuxNextFeed), so this feed has its own small card.
import { useMemo } from "react";
import { startOfDay, timeline, type TimelineEvent, type TimelineKind } from "../model";
import { agentsOf, Loaded, machineLabel, PRChip } from "../parts";
import type { ChiefViewProps } from "../registry";
import type { StatusGlyphName } from "../../../ui/statusGlyphs.generated";
import { StatusGlyph } from "../../../ui/StatusGlyph";

const GLYPH: Record<TimelineKind, StatusGlyphName> = {
  spawned: "working",
  waiting: "waiting",
  failed: "error",
  finished: "done",
  opened: "idle",
  merged: "done",
};

export function TimelineView({ data, strings, now, onOpenAgent, onOpenURL }: ChiefViewProps) {
  const agents = agentsOf(data);
  const landing = data.landing.status === "ready" ? data.landing.reply : undefined;
  const today = startOfDay(now);
  const events = useMemo(() => timeline(agents, landing, today), [agents, landing, today]);
  const clock = useMemo(
    () => new Intl.DateTimeFormat(strings.language, { hour: "numeric", minute: "2-digit" }),
    [strings.language],
  );
  const open = (event: TimelineEvent) => {
    if (event.agent) onOpenAgent(event.agent);
    else if (event.pr) onOpenURL(event.pr.url);
  };
  return (
    <Loaded status={data.agents.status} strings={strings}>
      {events.length === 0 ? (
        <p className="cv-note">{strings.t("chiefViews.timeline.empty")}</p>
      ) : (
        <ol className="cv-feed">
          {events.map((event) => (
            <li key={event.id} className="cv-event" data-kind={event.kind}>
              <button type="button" className="cv-event-button" onClick={() => open(event)}>
                <time className="cv-event-time" dateTime={new Date(event.at).toISOString()}>
                  {clock.format(event.at)}
                </time>
                <span className="cv-event-rail" aria-hidden="true">
                  <StatusGlyph name={GLYPH[event.kind]} size={10} />
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
          ))}
        </ol>
      )}
    </Loaded>
  );
}
