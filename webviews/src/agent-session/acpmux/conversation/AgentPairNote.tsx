// A paused agent pair (agentPairs.ts), drawn as a quiet tool row like a failover note
// (CompactionNote.tsx): which agent this chat stopped hearing from and why, how many of its
// messages wait, and Resume, which asks acpmux to deliver them (`_acpmux/agent_pair_resume`).
// "Show held messages" lists the held previews. Once the pair resumes the row is one line:
// "Resumed messages with <peer>", with how many acpmux delivered when it says.
import { useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxAgentPair } from "../model";
import { Envelope, PauseCircle } from "./icons";

export type ResumeAgentPair = (peer: string) => Promise<unknown>;

export function AgentPairNote({ pair, onResume }: { pair: AcpmuxAgentPair; onResume?: ResumeAgentPair }) {
  const t = useT();
  const [state, setState] = useState<"idle" | "pending" | "failed">("idle");
  const [showHeld, setShowHeld] = useState(false);
  const peer = pair.peerName || t("agentPair.peerFallback");
  if (pair.resumed)
    return (
      <div className="cv-tools">
        <div className="cv-tool cv-agent-pair" data-state="resumed">
          <span className="cv-tool__icon">
            <Envelope />
          </span>
          <span className="cv-tool__text">
            {pair.delivered
              ? t("agentPair.resumedDelivered", { peer, n: pair.delivered })
              : t("agentPair.resumed", { peer })}
          </span>
        </div>
      </div>
    );
  const reason =
    pair.reason === "repeating"
      ? t("agentPair.paused.repeating", { peer, n: pair.count })
      : t("agentPair.paused.alternating", { peer, n: pair.count });
  const resume = () => {
    if (!onResume || state === "pending") return;
    setState("pending");
    onResume(pair.peer).then(
      () => setState("idle"),
      () => setState("failed"),
    );
  };
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-agent-pair" data-state="paused">
        <span className="cv-tool__icon">
          <PauseCircle />
        </span>
        <span className="cv-tool__text cv-agent-pair__text">{reason}</span>
      </div>
      <div className="cv-agent-pair__detail">
        {pair.held > 0 && <span>{t("agentPair.held", { n: pair.held })}</span>}
        {state === "failed" && <span className="cv-agent-pair__failed">{t("agentPair.resumeFailed")}</span>}
        {onResume && (
          <button type="button" className="cv-agent-pair__resume" disabled={state === "pending"} onClick={resume}>
            {t("agentPair.resume")}
          </button>
        )}
        {pair.heldTexts.length > 0 && (
          <button
            type="button"
            className="cv-agent-pair__toggle"
            aria-expanded={showHeld}
            onClick={() => setShowHeld((open) => !open)}
          >
            {t(showHeld ? "agentPair.hideHeld" : "agentPair.showHeld")}
          </button>
        )}
      </div>
      {showHeld && pair.heldTexts.length > 0 && (
        <ul className="cv-agent-pair__held">
          {pair.heldTexts.map((text, index) => (
            <li key={index}>{text}</li>
          ))}
        </ul>
      )}
    </div>
  );
}
