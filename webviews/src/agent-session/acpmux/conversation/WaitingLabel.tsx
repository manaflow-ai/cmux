// The running turn's words while the chat waits on the person (waitingOn.ts), for Thinking.tsx and
// WorkingFor.tsx. The trust question's wait names what it trusts ("Waiting for you to trust
// atlas-web") and points down at the question above the composer: a click brings it into view and
// onto its first answer, so the line never reads as the agent still working (Leo, 2026-10-21:
// Claude "thinks" forever until you click Trust).
import { type ReactNode, useContext } from "react";
import { useT } from "../i18n";
import { ArrowDown } from "./icons";
import { WAITING_LABEL, WaitingOnContext, WaitingTrustContext, type WaitingOn } from "./waitingOn";

/// The chat's wait (`on`, waitingOn.ts `chatWaitsOn`) and the trust question's subject by name
/// (`trust`, TrustAsk.tsx `trustAskName`), for the turn's lines under it.
export function WaitingProvider({ on, trust, children }: { on?: WaitingOn; trust?: string; children: ReactNode }) {
  return (
    <WaitingOnContext.Provider value={on}>
      <WaitingTrustContext.Provider value={trust}>{children}</WaitingTrustContext.Provider>
    </WaitingOnContext.Provider>
  );
}

/// Scrolls the open trust question (TrustAsk.tsx, `data-asking`) into view and focuses its primary
/// answer.
export function revealTrustAsk(document: Document): void {
  const ask = document.querySelector<HTMLElement>(".acpmux-trust-ask[data-asking]");
  if (!ask) return;
  ask.scrollIntoView({ block: "nearest" });
  ask.querySelector<HTMLElement>(".acpmux-trust-ask-primary")?.focus();
}

export function WaitingLabel({ waiting, className }: { waiting: WaitingOn; className: string }) {
  const t = useT();
  const name = useContext(WaitingTrustContext);
  if (waiting !== "trust")
    return (
      <output className={className} data-waiting={waiting}>
        {t(WAITING_LABEL[waiting])}
      </output>
    );
  return (
    <output className={className} data-waiting={waiting}>
      <button
        type="button"
        className="cv-waiting__show"
        onClick={(event) => revealTrustAsk(event.currentTarget.ownerDocument)}
      >
        <span className="cv-waiting__words">
          {name ? t("turn.waiting.trustNamed", { name }) : t(WAITING_LABEL.trust)}
        </span>
        <ArrowDown size={12} />
      </button>
    </output>
  );
}
