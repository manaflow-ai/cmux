// Another agent's message to this chat (incomingMessage.ts), as Claude Code desktop draws one: a
// quiet line, "Received message from <sender> ›", the words muted and the sender underlined when it
// is a chat here, which opens beside this one. Folded by default; opened (the chevron turns ⌄) the
// message follows as plain text, with no bubble, border or fill. Whether it is open is kept for the
// chat across reloads (transcriptDisclosure.tsx). A sub-session family's sender says who it is to
// this chat in its tooltip ("Parent · coordinator").
import { useId } from "react";
import { useT, type StringKey } from "../i18n";
import type { PromptImage } from "../model";
import type { IncomingMessage, IncomingRelation } from "./incomingMessage";
import { SentImages } from "./UserBubble";
import { ChevronRight, TerminalSquare } from "./icons";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import "./IncomingMessageCard.css";

/// A family sender's label, its relation before its name.
const RELATION_LABEL: Record<IncomingRelation, StringKey> = {
  parent: "message.from.parent",
  subsession: "message.from.subsession",
  ancestor: "message.from.ancestor",
  descendant: "message.from.descendant",
};

/// Stands in for the sender in the translated line, so the sender can be drawn as its link.
const NAME = "\u2063name\u2063";

export function IncomingMessageCard({
  message,
  images,
  onOpen,
  disclosureKey,
}: {
  message: IncomingMessage;
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  onOpen(sessionId: string): void;
  /// Where its open state is kept in the chat's transcript state (the row's id).
  disclosureKey: string;
}) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  const bodyId = useId();
  const line = t("message.received", { name: NAME });
  const at = line.indexOf(NAME);
  const before = at < 0 ? line : line.slice(0, at);
  const after = at < 0 ? "" : line.slice(at + NAME.length);
  const relation = message.relation ? t(RELATION_LABEL[message.relation], { name: message.name }) : undefined;
  const sessionId = message.sessionId;
  const toggle = () => setOpen((value) => !value);
  return (
    <div className="cv-received">
      <div className="cv-received__line">
        <button
          type="button"
          className="cv-received__words"
          aria-expanded={open}
          aria-controls={open ? bodyId : undefined}
          onClick={toggle}
        >
          {before.trimEnd()}
        </button>
        {sessionId ? (
          <button
            type="button"
            className="cv-received__sender is-link"
            aria-label={t("subagents.open", { name: message.name })}
            /* tooltip-allow: the line names the sender; who it is to this chat shows nowhere else */
            title={relation}
            onClick={() => onOpen(sessionId)}
          >
            {message.name}
          </button>
        ) : (
          /* tooltip-allow: the line names the sender; who it is to this chat shows nowhere else */
          <span className="cv-received__sender" title={relation}>
            {message.name}
          </span>
        )}
        {after.trim() && <span className="cv-received__words is-text">{after.trim()}</span>}
        <button
          type="button"
          className="cv-received__chevron"
          aria-expanded={open}
          aria-controls={open ? bodyId : undefined}
          aria-label={t(open ? "message.less" : "message.more")}
          onClick={toggle}
        >
          <ChevronRight size={14} strokeWidth={1.2} className={`cv-rotor${open ? " is-open" : ""}`} />
        </button>
      </div>
      {open && (
        <div id={bodyId} className="cv-received__body selectable">
          {message.text || t("message.noText")}
          {images && images.length > 0 && <SentImages images={images} className="cv-received__images" />}
        </div>
      )}
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
