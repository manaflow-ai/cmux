// Another agent's message to this chat (incomingMessage.ts) as Claude desktop draws one: a quiet
// line, "Received message from <sender> ›", never the person's bubble and never folded away. The
// sender's name opens its chat beside this one when it is a chat here; › opens the message under
// the line (and, for a Claude Code envelope, the prompt as the agent got it). Whether it is open
// lasts while the page does, so scrolling it out of the virtualized transcript keeps it.
import { useId, useState } from "react";
import { useT } from "../i18n";
import type { PromptImage } from "../model";
import type { IncomingMessage } from "./incomingMessage";
import { SentImages } from "./UserBubble";
import { ChevronRight, TerminalSquare } from "./icons";

/// The rows whose message the person opened.
const opened = new Set<string>();

export function IncomingMessageLine({
  id,
  message,
  images,
  onOpen,
}: {
  /// The row's id, which keeps the line open across remounts.
  id: string;
  message: IncomingMessage;
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  onOpen(sessionId: string): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(() => opened.has(id));
  const toggle = () =>
    setOpen((value) => {
      if (value) opened.delete(id);
      else opened.add(id);
      return !value;
    });
  const bodyId = useId();
  // The name sits where the sentence puts it ("Received message from {title}").
  const [before, after = ""] = t("offer.received", { title: "\u0000" }).split("\u0000");
  const raw = message.raw.trim() === message.text ? undefined : message.raw;
  const sessionId = message.sessionId;
  const label = t("message.label", { from: message.name, to: t("message.self") });
  return (
    <div className="cv-received" data-open={open || undefined}>
      <div className="cv-received__line">
        {/* The sentence toggles too, for the pointer; the chevron is the control, and its label reads
            the line. */}
        <span className="cv-received__text" aria-hidden onClick={toggle}>
          {before}
        </span>
        {sessionId ? (
          <button
            type="button"
            className="cv-received__name"
            aria-label={t("subagents.open", { name: message.name })}
            onClick={() => onOpen(sessionId)}
          >
            {message.name}
          </button>
        ) : (
          <span className="cv-received__name is-plain" aria-hidden onClick={toggle}>
            {message.name}
          </span>
        )}
        {after && (
          <span className="cv-received__text" aria-hidden onClick={toggle}>
            {after}
          </span>
        )}
        <button
          type="button"
          className="cv-received__toggle"
          aria-expanded={open}
          aria-controls={bodyId}
          aria-label={label}
          onClick={toggle}
        >
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
        </button>
      </div>
      {open && (
        <div id={bodyId} className="cv-received__body selectable">
          {message.text || t("message.noText")}
        </div>
      )}
      {open && raw !== undefined && <pre className="cv-tool-output selectable">{raw}</pre>}
      {images && images.length > 0 && <SentImages images={images} className="cv-message__images" />}
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
