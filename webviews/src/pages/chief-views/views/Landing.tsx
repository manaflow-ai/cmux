// Landing: the repository's pull requests by where they are on the way in. Open, labeled
// `ready-to-land`, CI red (the fleet dashboard's run for it failed) and merged today, each with
// the agents that work on it.
import { useMemo } from "react";
import { landingLanes, startOfDay, type PRCard } from "../model";
import { agentsOf, Loaded } from "../parts";
import type { ChiefViewProps } from "../registry";
import { PRCardRow } from "./AgentBoard";

export function LandingView({ data, strings, now, placement, onOpenURL }: ChiefViewProps) {
  const agents = agentsOf(data);
  const fleetPRs = data.fleet.status === "ready" ? data.fleet.reply.prs : undefined;
  const landing = "reply" in data.landing ? data.landing.reply : undefined;
  const today = startOfDay(now);
  const lanes = useMemo(() => landingLanes(landing, agents, fleetPRs, today), [landing, agents, fleetPRs, today]);
  const sections: { id: string; title: string; prs: PRCard[] }[] = [
    { id: "ready", title: strings.t("chiefViews.landing.ready"), prs: lanes.ready },
    { id: "red", title: strings.t("chiefViews.landing.red"), prs: lanes.red },
    { id: "open", title: strings.t("chiefViews.landing.open"), prs: lanes.open },
    { id: "merged", title: strings.t("chiefViews.landing.merged"), prs: lanes.merged },
  ];
  return (
    <div className="cv-landing" data-placement={placement}>
      <Loaded
        status={data.landing.status === "loading" && landing ? "ready" : data.landing.status}
        strings={strings}
        unavailable={<p className="cv-note">{strings.t("chiefViews.landing.unavailable")}</p>}
      >
        {landing && (
          <p className="cv-caption">
            {landing.repo} · {landing.base}
          </p>
        )}
        {sections.map((section) => (
          <section key={section.id} className="cv-machine" data-lane={section.id} aria-label={section.title}>
            <h3 className="cv-machine-head">
              <span className="cv-machine-name">{section.title}</span>
              <span className="cv-machine-count">{section.prs.length}</span>
            </h3>
            {section.prs.length === 0 ? (
              <p className="cv-column-empty">{strings.t("chiefViews.board.empty")}</p>
            ) : (
              <ul className="cv-rows">
                {section.prs.map((pr) => (
                  <PRCardRow key={pr.number} pr={pr} now={now} strings={strings} onOpenURL={onOpenURL} />
                ))}
              </ul>
            )}
          </section>
        ))}
      </Loaded>
    </div>
  );
}
