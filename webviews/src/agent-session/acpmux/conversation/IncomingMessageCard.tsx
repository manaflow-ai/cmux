// Another agent's message to this chat (incomingMessage.ts) as MessageCard draws one this agent
// sent: sender to this agent, the message's first two lines, and the whole message once opened.
// Opened, a Claude Code envelope also shows the prompt as the agent got it; a sender that is a
// chat here opens beside this one.
import { useId, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { PromptImage } from "../model";
import type { IncomingMessage } from "./incomingMessage";
import { SentImages } from "./UserBubble";
import { ArrowRight, ChevronDown, ChevronRight, Envelope, TerminalSquare } from "./icons";

export function IncomingMessageCard({
  message,
  images,
  onOpen,
}: {
  message: IncomingMessage;
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  onOpen(sessionId: string): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const to = t("message.self");
  // As MessageCard: a first guess, then the clamped body measures itself.
  const [long, setLong] = useState(() => message.text.split("\n").length > 2 || message.text.length > 140);
  const body = useRef<HTMLDivElement>(null);
  const bodyId = useId();
  useLayoutEffect(() => {
    const node = body.current;
    if (!node || open) return;
    const measure = () => setLong(node.scrollHeight > node.clientHeight + 1);
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [open, message.text]);
  const raw = message.raw.trim() === message.text ? undefined : message.raw;
  const sessionId = message.sessionId;
  return (
    <div className="cv-message is-incoming">
      <button
        type="button"
        className="cv-message__head"
        aria-expanded={open}
        aria-controls={bodyId}
        aria-label={t("message.label", { from: message.name, to })}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-message__route">
          <span className="cv-tool__icon">
            <Envelope />
          </span>
          <span className="cv-message__party">{message.name}</span>
          <ArrowRight size={12} className="cv-message__arrow" />
          <span className="cv-message__party is-to">{to}</span>
          <ChevronRight
            size={14}
            strokeWidth={1.2}
            className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
          />
        </span>
      </button>
      <div ref={body} id={bodyId} className={`cv-message__body selectable${open ? "" : " is-clamped"}`}>
        {message.text || t("message.noText")}
      </div>
      {images && images.length > 0 && <SentImages images={images} className="cv-message__images" />}
      {(long || raw !== undefined || sessionId) && (
        <div className="cv-message__foot">
          {(long || raw !== undefined) && (
            <button
              type="button"
              className="cv-message__more"
              aria-expanded={open}
              aria-controls={bodyId}
              onClick={() => setOpen((value) => !value)}
            >
              {t(open ? "message.less" : "message.more")}
              <ChevronDown size={12} className={`cv-rotor${open ? " is-flipped" : ""}`} />
            </button>
          )}
          {sessionId && (
            <button type="button" className="cv-message__more" onClick={() => onOpen(sessionId)}>
              {t("subagents.open", { name: message.name })}
            </button>
          )}
        </div>
      )}
      {open && raw !== undefined && <pre className="cv-tool-output selectable">{raw}</pre>}
    </div>
  );
}

/// A Claude Code task notification in a prompt: its summary, drawn as BackgroundTaskNote draws a
/// background shell's end.
export function IncomingNotice({ text }: { text: string }) {
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-bgtask">
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text">{text}</span>
      </div>
    </div>
  );
}
