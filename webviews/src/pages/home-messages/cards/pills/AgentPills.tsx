// An agents row as one pill per agent (Swift `HomeAgentPills`, user 2026-11-03: the ChatGPT look):
// a status mark (a turning arc while it works, a check once it reported, a cross when it stopped,
// a still clock while it waits for a slot), its title, an unread dot for a report and a `›`. A
// click opens the agent (the pane, or its workspace beside Home). Chips keep one row: a chip that
// does not fit is left out, so the row's height never depends on its width.
import { Spinner } from "../../../../agent-session/acpmux/conversation/icons";
import { Icon } from "../../../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../strings";
import { agentPills, agentStatus, type AgentPeerState, type AgentPillShape, type AgentsRow } from "./agentModel";
import "../cards.css";

export interface AgentPillsProps {
  row: AgentsRow;
  shape?: AgentPillShape;
  strings: Strings;
  /** A click on `peer`'s pill; `command` with ⌘ held. */
  onOpen(peer: string, command: boolean): void;
}

export function AgentPills({ row, shape = "pill", strings, onOpen }: AgentPillsProps) {
  const pills = agentPills(row);
  return (
    <ul className="hm-pills" data-shape={shape}>
      {pills.map((pill) => {
        const status = agentStatus(pill.state, strings);
        return (
          <li key={pill.peer} className="hm-pills__item">
            <button
              type="button"
              className="hm-pill"
              data-state={pill.state}
              data-unread={pill.unread ? "" : undefined}
              aria-label={`${pill.title}, ${status}`}
              onClick={(event) => onOpen(pill.peer, event.metaKey)}
            >
              <PillMark state={pill.state} />
              <span className="hm-pill__text">
                <span className="hm-pill__title">{pill.title}</span>
                {shape === "twoLine" && <span className="hm-pill__status">{`${status} · ${pill.peer}`}</span>}
              </span>
              {pill.unread && <Icon name="unread.dot" size={12} className="hm-pill__dot" />}
              <span className="hm-pill__chevron" aria-hidden="true">
                <svg viewBox="0 0 12 12" width="12" height="12">
                  <path
                    d="M4 1.5 8.5 6 4 10.5"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.6"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

/** The status mark: a check (reported), a cross (stopped), a still clock (queued: nothing runs
 * yet), else the turning arc (working). */
export function PillMark({ state }: { state: AgentPeerState }) {
  if (state === "told") return <Spinner className="hm-pill__mark" size={16} loading />;
  return (
    <svg className="hm-pill__mark" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <g fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
        <circle cx="8" cy="8" r="6" />
        {state === "reported" && <path d="M5.3 8.1 7.4 10.3 11 5.9" />}
        {state === "stopped" && <path d="M5.7 5.7 10.3 10.3M10.3 5.7 5.7 10.3" />}
        {state === "queued" && <path d="M8 4.7V8l2.5 1.8" />}
      </g>
    </svg>
  );
}
