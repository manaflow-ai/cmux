// A sub-session as the transcript's cards draw it (conversation/SubsessionCallCard.tsx): a glass
// card with its harness's mark, its name, the model it runs, its state (the working spinner while
// its turn runs, never a dot; "Waiting on you"; Done; Failed), what its turn does now under that,
// and "Open chat", which opens its chat beside this one without taking focus. What the card adds
// (a prompt, a reply, the call's raw JSON) comes as `children`. Its state is read live by the
// caller from the session list (subsessions.ts `useSubsessionInfo`); the card itself reads nothing.
import type { ReactNode } from "react";
import { AgentMark, knownMark } from "../../shared/AgentMark";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { SUBSESSION_STATE_LABEL, type SubsessionState } from "./subsessions";
import "./AgentCard.css";

export type AgentCardProps = {
  name: string;
  /// Its harness (`claude`, `codex`, or a profile such as `claude-sr2`), for its mark.
  harness?: string;
  model?: string;
  /// Undefined while the session list does not have it (a gallery, an archived chat).
  state?: SubsessionState;
  /// What its turn does now, or what it waits on the person for.
  doing?: string;
  /// Messages waiting behind its running turn.
  queued?: number;
  onOpen?: () => void;
  children?: ReactNode;
};

export function AgentCard({ name, harness, model, state, doing, queued, onOpen, children }: AgentCardProps) {
  const t = useT();
  // A profile names its family first (`claude-sr2`): its family's mark when it has none.
  const mark = harness ? knownMark(harness, harness.split(/[-_/]/)[0]) : undefined;
  return (
    <div className="cv-agent-card" data-state={state}>
      <div className="cv-agent-card__head">
        <span className="cv-agent-card__icon" aria-hidden>
          {mark ? <AgentMark agent={mark} size={14} /> : <Icon name="agent.session" size={16} />}
        </span>
        <span className="cv-agent-card__name">{name}</span>
        {model && <span className="cv-agent-card__model">{model}</span>}
        {state && (
          <span className="cv-agent-card__state" data-state={state}>
            {state === "working" && <Spinner size={12} />}
            {t(SUBSESSION_STATE_LABEL[state])}
            {queued ? ` · ${t("subsession.queued", { n: queued })}` : ""}
          </span>
        )}
        {onOpen && (
          <button
            type="button"
            className="cv-agent-card__open"
            aria-label={t("subagents.open", { name })}
            onClick={onOpen}
          >
            {t("subsession.openChat")}
          </button>
        )}
      </div>
      {doing && <div className="cv-agent-card__doing">{doing}</div>}
      {children}
    </div>
  );
}
