// Agent board: a kanban of four columns, Working, Needs you, Ready to land and Landed today. The
// first two hold agents; the last two hold pull requests with the agents on them.
import { useMemo } from "react";
import { boardColumns, branchPRs, landingLanes, startOfDay, type PRCard } from "../model";
import { AgentRow, agentsOf, Ago, CIChip, Loaded, OwnerChips, PRChip } from "../parts";
import type { ChiefViewProps } from "../registry";
import type { ChiefAgent } from "../types";
import type { Strings } from "../../shared/i18n";

type Column = { id: string; title: string; agents?: ChiefAgent[]; prs?: PRCard[] };

export function AgentBoardView({ data, strings, now, placement, onOpenAgent, onOpenURL }: ChiefViewProps) {
  const agents = agentsOf(data);
  const fleetPRs = data.fleet.status === "ready" ? data.fleet.reply.prs : undefined;
  const landing = data.landing.status === "ready" ? data.landing.reply : undefined;
  const today = startOfDay(now);
  const columns = useMemo(
    () => boardColumns(agents, landingLanes(landing, agents, fleetPRs, today)),
    [agents, landing, fleetPRs, today],
  );
  const prs = useMemo(() => branchPRs(fleetPRs), [fleetPRs]);
  const list: Column[] = [
    { id: "working", title: strings.t("chiefViews.board.working"), agents: columns.working },
    { id: "needs-you", title: strings.t("chiefViews.board.needsYou"), agents: columns.needsYou },
    { id: "ready", title: strings.t("chiefViews.board.ready"), prs: columns.ready },
    { id: "landed", title: strings.t("chiefViews.board.landed"), prs: columns.landed },
  ];
  return (
    <Loaded status={data.agents.status} strings={strings}>
      <div className="cv-board" data-placement={placement}>
        {list.map((column) => {
          const count = column.agents?.length ?? column.prs?.length ?? 0;
          return (
            <section key={column.id} className="cv-column" data-column={column.id} aria-label={column.title}>
              <h3 className="cv-column-head">
                <span>{column.title}</span>
                <span className="cv-column-count">{count}</span>
              </h3>
              {count === 0 ? (
                <p className="cv-column-empty">{strings.t("chiefViews.board.empty")}</p>
              ) : column.agents ? (
                <ul className="cv-rows cv-cards">
                  {column.agents.map((agent) => (
                    <AgentRow
                      key={`${agent.kind}:${agent.id}`}
                      agent={agent}
                      now={now}
                      strings={strings}
                      compact
                      showMachine
                      prs={prs}
                      onOpen={onOpenAgent}
                    />
                  ))}
                </ul>
              ) : (
                <ul className="cv-rows cv-cards">
                  {column.prs!.map((pr) => (
                    <PRCardRow key={pr.number} pr={pr} now={now} strings={strings} compact onOpenURL={onOpenURL} />
                  ))}
                </ul>
              )}
            </section>
          );
        })}
      </div>
    </Loaded>
  );
}

export function PRCardRow({
  pr,
  now,
  strings,
  compact,
  onOpenURL,
}: {
  pr: PRCard;
  now: number;
  strings: Strings;
  /** A board card: the title wraps and the CI chip and time move under it. */
  compact?: boolean;
  onOpenURL: (url: string) => void;
}) {
  const at = Date.parse(pr.mergedAt ?? pr.createdAt ?? "") || undefined;
  const meta = (
    <span className="cv-row-meta">
      <CIChip status={pr.ci} strings={strings} />
      <Ago at={at} now={now} strings={strings} />
    </span>
  );
  return (
    <li className="cv-row cv-pr-row" data-compact={compact ? "" : undefined}>
      <button type="button" className="cv-row-button" onClick={() => onOpenURL(pr.url)}>
        <PRChip number={pr.number} />
        <span className="cv-row-main">
          <span className="cv-row-head">
            <span className="cv-row-title">{pr.title}</span>
            {pr.draft && <span className="cv-chip">{strings.t("chiefViews.landing.draft")}</span>}
          </span>
          <span className="cv-row-sub">
            {pr.author && <span className="cv-row-author">{pr.author}</span>}
            <OwnerChips owners={pr.owners} strings={strings} />
          </span>
          {compact && meta}
        </span>
        {!compact && meta}
      </button>
    </li>
  );
}
