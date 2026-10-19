// l10n-allow-file: gallery prototype (sample transcript), not shipped UI.
// The typing indicator of Chief and of an agent: before the first token (the model is working),
// while it streams, while it runs a tool, and when it is done. Five designs: three crisp dots, a
// shimmer word with elapsed time (cnx-ios WorkingLabel), a Messages typing bubble, a block caret,
// and a status line attached to the composer.
import { GlassCircle, MacWindow, Phone, Shimmer, type Platform } from "./parts";
import "./subagents.css";

export type TypingDesign = "dots" | "shimmer" | "bubble" | "caret" | "composer";
export type TypingPhase = "waiting" | "streaming" | "tool" | "done";

export type TypingIndicatorProps = {
  platform: Platform;
  design: TypingDesign;
  phase: TypingPhase;
  who?: "chief" | "agent";
  /** Seconds since the turn started (the shimmer shows it from 5 s). */
  elapsed?: number;
};

const ANSWER =
  "Three agents are still running. Queue store finished its edit and the tests pass; Conflict rules is waiting on your answer about deletes";

function Dots() {
  return (
    <span className="sa-dots" aria-label="Typing">
      <i />
      <i />
      <i />
    </span>
  );
}

function Indicator({ design, phase, elapsed, name }: { design: TypingDesign; phase: TypingPhase; elapsed: number; name: string }) {
  const word = phase === "tool" ? "Checking the agents" : phase === "streaming" ? "Writing" : "Thinking";
  if (phase === "done") return null;
  switch (design) {
    case "dots":
      return phase === "streaming" ? null : <Dots />;
    case "bubble":
      return phase === "streaming" ? null : (
        <span className="sa-typing-bubble">
          <Dots />
        </span>
      );
    case "shimmer":
      return phase === "streaming" ? null : (
        <span className="sa-working">
          <Shimmer>{word}</Shimmer>
          {elapsed >= 5 && <span className="sa-muted"> · {elapsed}s</span>}
        </span>
      );
    case "caret":
      return phase === "streaming" ? null : (
        <span className="sa-caret-line">
          <span className="sa-caret" aria-label={`${name} is ${word.toLowerCase()}`} />
          {phase === "tool" && <span className="sa-muted"> {word}</span>}
        </span>
      );
    case "composer":
      return null;
  }
}

export function TypingIndicator({ platform, design, phase, who = "chief", elapsed = 12 }: TypingIndicatorProps) {
  const name = who === "chief" ? "Chief" : "Claude";
  const text = phase === "streaming" ? ANSWER.slice(0, 96) : phase === "done" ? `${ANSWER}.` : "";
  const streamingTail =
    phase === "streaming" && (design === "caret" ? <span className="sa-caret sa-caret-inline" aria-hidden="true" /> : null);
  const reply =
    who === "chief" && platform === "iphone" ? (
      text ? (
        <div className="sa-bubble sa-bubble-chief">
          {text}
          {streamingTail}
        </div>
      ) : null
    ) : text ? (
      <p className="sa-prose">
        {text}
        {streamingTail}
        {phase === "streaming" && design !== "caret" && design !== "composer" && <span className="sa-stream-fade" aria-hidden="true" />}
      </p>
    ) : null;
  const composerLine =
    design === "composer" && phase !== "done" ? (
      <div className="sa-composer-status">
        <Shimmer>
          {name} is {phase === "streaming" ? "writing" : phase === "tool" ? "checking the agents" : "thinking"}
        </Shimmer>
        <span className="sa-muted">{elapsed}s</span>
        <span className="sa-spacer" />
        <button type="button" className="sa-text-button">
          Stop
        </button>
      </div>
    ) : null;
  const body = (
    <>
      <div className="sa-bubble sa-bubble-user">How are the offline sync agents doing?</div>
      {reply}
      <div className="sa-indicator-slot">
        <Indicator design={design} phase={phase} elapsed={elapsed} name={name} />
      </div>
    </>
  );
  if (platform === "iphone")
    return (
      <Phone
        toolbar={
          <>
            <GlassCircle glyph="menu" label="Teams" />
            <span className="sa-phone-title">
              <strong>{name}</strong>
            </span>
            <GlassCircle glyph="compose" label="New thread" />
          </>
        }
      >
        <div className="sa-chat" data-platform="iphone" data-who={who}>
          {body}
        </div>
        {composerLine && <div className="sa-phone-composer-status">{composerLine}</div>}
        <div className="sa-phone-composer">
          <span className="sa-muted">Message</span>
          <span className="sa-send" data-stop={phase !== "done" || undefined} aria-hidden="true" />
        </div>
      </Phone>
    );
  return (
    <MacWindow title={who === "chief" ? "Home" : "cnx-ios"} sidebarWidth={220} sidebar={<div className="sa-sidebar-placeholder" />}>
      <div className="sa-chat" data-platform="mac" data-who={who}>
        {body}
        <div className="sa-mac-composer">
          {composerLine}
          <div className="sa-mac-composer-box">
            <span className="sa-muted">Message {name}</span>
            <span className="sa-send" data-stop={phase !== "done" || undefined} aria-hidden="true" />
          </div>
        </div>
      </div>
    </MacWindow>
  );
}
