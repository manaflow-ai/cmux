// A sub-session as the transcript's cards draw it (conversation/SubsessionCallCard.tsx): its
// harness's mark, name, model, state (the working spinner, never a dot) and what its turn does now;
// with `onOpen` its line is the chat's button, no "Open chat" word beside it (Leo, 2026-10-29: "Just
// have the thing be clickable, and then you can open it."). The caller reads its state live
// (subsessions.ts) and adds a prompt or a reply below.
import type { ReactNode } from "react";
import { useAgentAvatar } from "../agentAvatar";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { SUBSESSION_STATE_LABEL, type SubsessionState } from "./subsessions";
import { DisclosureRow, type DisclosureRowProps } from "./DisclosureRow";
import { AgentIdentity } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import "./AgentCard.css";

export type AgentCardProps = {
  name: string;
  /// Its harness (`claude`, `codex`, or a profile such as `claude-sr2`), for its mark.
  harness?: string;
  /// Its acpmux session, whose own avatar (Set Avatar…, agentAvatar.ts) replaces the mark.
  sessionId?: string;
  /// Stable list identity, for the icon's tone when the harness has no mark.
  identity?: string;
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
  onOpen?: () => void;
  /// The line's tooltip when it opens the chat: "Open {name}" when absent.
  openLabel?: string;
  /// Draw this card as a one-line transcript disclosure with its children in a panel.
  disclosure?: boolean;
  disclosureKey?: string;
  findItems?: DisclosureRowProps["findItems"];
  /// The complete localized disclosure label, with its name in the locale's word order.
  disclosureLabel?: ReactNode;
  children?: ReactNode;
};

export function AgentCard({
  name,
  harness,
  sessionId,
  identity,
  model,
  state,
  doing,
  queued,
  slot,
  time,
  stateLabel,
  onOpen,
  openLabel,
  disclosure = false,
  disclosureKey,
  findItems,
  disclosureLabel,
  children,
}: AgentCardProps) {
  const t = useT();
  // A profile names its family first (`claude-sr2`): AgentIdentity draws its family's mark when it
  // has none, else the session icon in the card's own stable tone.
  const tone = agentTone(identity ?? sessionId ?? name);
  const avatar = useAgentAvatar(sessionId);
  const stateText = state
    ? slot
      ? t("subsession.state.slot")
      : (stateLabel ?? t(SUBSESSION_STATE_LABEL[state]))
    : undefined;
  if (disclosure) {
    const liveDetail = state === "input" || state === "failed" || slot ? doing : undefined;
    return (
      <DisclosureRow
        disclosureKey={disclosureKey ?? `subsession:${sessionId ?? name}`}
        findItems={findItems}
        icon={
          avatar ? (
            <img className="cv-agent-avatar" src={avatar} alt="" width={16} height={16} />
          ) : (
            <AgentIdentity
              harness={harness}
              tone={tone}
              size={14}
              fallbackNode={<Icon name="agent.session" size={16} />}
            />
          )
        }
        label={disclosureLabel ?? name}
        meta={model}
        status={
          stateText && (
            <>
              {state === "working" && !slot && <Spinner size={12} loading />}
              {stateText}
              {queued ? ` · ${t("subsession.queued", { n: queued })}` : ""}
              {time ? ` · ${time}` : ""}
              {liveDetail ? ` · ${liveDetail}` : ""}
            </>
          )
        }
        openLabel={openLabel ?? t("subagents.open", { name })}
        onOpen={onOpen}
      >
        {children}
      </DisclosureRow>
    );
  }
  const head = (
    <>
      <span className="cv-agent-card__icon" aria-hidden>
        {avatar ? (
          <img className="cv-agent-avatar" src={avatar} alt="" width={16} height={16} />
        ) : (
          <AgentIdentity
            harness={harness}
            tone={tone}
            size={14}
            fallbackNode={<Icon name="agent.session" size={16} />}
          />
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
    </>
  );
  return (
    <div className="cv-agent-card" data-state={state}>
      {onOpen ? (
        <button
          type="button"
          className="cv-agent-card__head is-open-chat"
          title={openLabel ?? t("subagents.open", { name })}
          onClick={onOpen}
        >
          {head}
        </button>
      ) : (
        <div className="cv-agent-card__head">{head}</div>
      )}
      {doing && <div className="cv-agent-card__doing">{doing}</div>}
      {children}
    </div>
  );
}
