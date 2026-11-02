// A paused agent pair (agentPairs.ts), drawn as a quiet tool row like a failover note
// (CompactionNote.tsx): which agent this chat stopped hearing from and why, how many of its
// messages wait, and Resume, which asks acpmux to deliver them (`_acpmux/agent_pair_resume`).
// "Show held messages" lists the held previews. Once the pair resumes the row is one line:
// "Resumed messages with <peer>", with how many acpmux delivered, and apart, how many it dropped.
import { useId, useRef, useState } from "react";
import { type PaneLanguage, type Translate, usePaneLanguage, useT } from "../i18n";
import type { AcpmuxAgentPair } from "../model";
import { Envelope, PauseCircle } from "./icons";
import { sliceWhole } from "../../../ui/wholeChars";

export type ResumeAgentPair = (peer: string) => Promise<unknown>;

/// The held list shows this many previews, then "and N more".
const SHOWN_HELD = 20;
/// acpmux sends at most 200 characters of each; a longer one is cut here too.
const PREVIEW_CHARS = 200;
const preview = (text: string) => (text.length > PREVIEW_CHARS ? `${sliceWhole(text, PREVIEW_CHARS)}…` : text);

/// The cap's window in words, in the pane language: "10 minutes", "2 hours", "90 seconds" (the
/// largest unit that divides it).
export function spelledWindow(seconds: number, language: PaneLanguage): string {
  const [unit, value] =
    seconds >= 3600 && seconds % 3600 === 0
      ? (["hour", seconds / 3600] as const)
      : seconds >= 60 && seconds % 60 === 0
        ? (["minute", seconds / 60] as const)
        : (["second", seconds] as const);
  return new Intl.NumberFormat(language, { style: "unit", unit, unitDisplay: "long" }).format(value);
}

function reasonText(t: Translate, language: PaneLanguage, pair: AcpmuxAgentPair, peer: string): string {
  switch (pair.reason) {
    case "repeating":
      return t("agentPair.paused.repeating", { peer, n: pair.count });
    case "cap":
      return t("agentPair.paused.cap", { peer, n: pair.count, window: spelledWindow(pair.windowSecs ?? 0, language) });
    case "release_failed":
      return t("agentPair.paused.releaseFailed", { peer });
    default:
      return t("agentPair.paused.alternating", { peer, n: pair.count });
  }
}

export function AgentPairNote({ pair, onResume }: { pair: AcpmuxAgentPair; onResume?: ResumeAgentPair }) {
  const t = useT();
  const language = usePaneLanguage();
  const [state, setState] = useState<"idle" | "pending" | "failed">("idle");
  // A second click before React draws "pending" must not send a second resume.
  const sending = useRef(false);
  const [showHeld, setShowHeld] = useState(false);
  const listId = useId();
  const peer = pair.peerName || t("agentPair.peerFallback");
  const dropped = pair.dropped > 0 && (
    <span className="cv-agent-pair__dropped">{t("agentPair.dropped", { n: pair.dropped })}</span>
  );
  if (pair.resumed)
    return (
      <div className="cv-tools">
        <div className="cv-tool cv-agent-pair" data-state="resumed">
          <span className="cv-tool__icon">
            <Envelope />
          </span>
          <span className="cv-tool__text">
            {pair.released > 0
              ? t("agentPair.resumedDelivered", { peer, n: pair.released })
              : t("agentPair.resumed", { peer })}
          </span>
          {dropped}
        </div>
      </div>
    );
  const resume = () => {
    if (!onResume || sending.current) return;
    sending.current = true;
    setState("pending");
    onResume(pair.peer).then(
      () => {
        sending.current = false;
        setState("idle");
      },
      () => {
        sending.current = false;
        setState("failed");
      },
    );
  };
  const held = pair.held;
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-agent-pair" data-state="paused">
        <span className="cv-tool__icon">
          <PauseCircle />
        </span>
        {/* tooltip-allow: the pause's raw error shows nowhere else; the note's text only summarizes it. */}
        <span className="cv-tool__text cv-agent-pair__text" title={pair.error}>
          {reasonText(t, language, pair, peer)}
        </span>
      </div>
      <div className="cv-agent-pair__detail">
        <output className="cv-agent-pair__status">
          {held.length > 0 && <span>{t("agentPair.held", { n: held.length })}</span>}
          {dropped}
          {state === "failed" && <span className="cv-agent-pair__failed">{t("agentPair.resumeFailed")}</span>}
        </output>
        {onResume && (
          <button type="button" className="cv-agent-pair__resume" disabled={state === "pending"} onClick={resume}>
            {t("agentPair.resume")}
          </button>
        )}
        {held.length > 0 && (
          <button
            type="button"
            className="cv-agent-pair__toggle"
            aria-expanded={showHeld}
            aria-controls={listId}
            onClick={() => setShowHeld((open) => !open)}
          >
            {t(showHeld ? "agentPair.hideHeld" : "agentPair.showHeld")}
          </button>
        )}
      </div>
      {showHeld && held.length > 0 && (
        <ul id={listId} className="cv-agent-pair__held">
          {held.slice(0, SHOWN_HELD).map((item) => (
            <li key={item.promptId}>{preview(item.text)}</li>
          ))}
          {held.length > SHOWN_HELD && (
            <li className="cv-agent-pair__more">{t("agentPair.moreHeld", { n: held.length - SHOWN_HELD })}</li>
          )}
        </ul>
      )}
    </div>
  );
}
