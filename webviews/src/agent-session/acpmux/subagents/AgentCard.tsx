// A sub-session as the transcript's cards draw it (conversation/SubsessionCallCard.tsx): its
// harness's mark, name, model, state (the working spinner, never a dot), what its turn does now, and
// "Open chat". The caller reads its state live (subsessions.ts) and adds a prompt or a reply below.
import type { MouseEvent, ReactNode } from "react";
import { AgentMark, knownMark } from "../../shared/AgentMark";
import { useAgentAvatar } from "../agentAvatar";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { SUBSESSION_STATE_LABEL, type SubsessionState } from "./subsessions";
import "./AgentCard.css";

export type AgentCardProps = {
  name: string;
  /// Its harness (`claude`, `codex`, or a profile such as `claude-sr2`), for its mark.
  harness?: string;
  /// Its acpmux session, whose own avatar (Set Avatar…, agentAvatar.ts) replaces the mark.
  sessionId?: string;
  model?: string;
  /// Undefined while the session list does not have it (a gallery, an archived chat).
  state?: SubsessionState;
  /// What its turn does now, or what it waits on the person for.
  doing?: string;
  /// Messages waiting behind its running turn.
  queued?: number;
  /// It waits for a run slot: it has not started, whatever its state says.
  slot?: boolean;
  /// How long it has run, or ran, after its state.
  time?: string;
  /// Its state's word when the state's own is not it (a run that was stopped).
  stateLabel?: string;
  onOpen?: (event: MouseEvent<HTMLButtonElement>) => void;
  /// The open button's word: "Open chat" when absent.
  openLabel?: string;
  children?: ReactNode;
};

export function AgentCard({
  name,
  harness,
  sessionId,
  model,
  state,
  doing,
  queued,
  slot,
  time,
  stateLabel,
  onOpen,
  openLabel,
  children,
}: AgentCardProps) {
  const t = useT();
  // A profile names its family first (`claude-sr2`): its family's mark when it has none.
  const mark = harness ? knownMark(harness, harness.split(/[-_/]/)[0]) : undefined;
  const avatar = useAgentAvatar(sessionId);
  return (
    <div className="cv-agent-card" data-state={state}>
      <div className="cv-agent-card__head">
        <span className="cv-agent-card__icon" aria-hidden>
          {avatar ? (
            <img className="cv-agent-avatar" src={avatar} alt="" width={16} height={16} />
          ) : mark ? (
            <AgentMark agent={mark} size={14} />
          ) : (
            <Icon name="agent.session" size={16} />
          )}
        </span>
        <span className="cv-agent-card__name">{name}</span>
        {model && <span className="cv-agent-card__model">{model}</span>}
        {state && (
          <span className="cv-agent-card__state" data-state={slot ? "slot" : state}>
            {state === "working" && <Spinner size={12} loading />}
            {slot ? t("subsession.state.slot") : (stateLabel ?? t(SUBSESSION_STATE_LABEL[state]))}
            {queued ? ` · ${t("subsession.queued", { n: queued })}` : ""}
            {time ? ` · ${time}` : ""}
          </span>
        )}
        {onOpen && (
          <button
            type="button"
            className="cv-agent-card__open"
            aria-label={t("subagents.open", { name })}
            onClick={onOpen}
          >
            {openLabel ?? t("subsession.openChat")}
          </button>
        )}
      </div>
      {doing && <div className="cv-agent-card__doing">{doing}</div>}
      {children}
    </div>
  );
}
