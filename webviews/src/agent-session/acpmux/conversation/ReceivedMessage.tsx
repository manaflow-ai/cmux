// A message another session sent this chat (receivedMessages.ts), as Claude desktop draws it:
// "Received message from <sender> ›", one muted line whose sender is a link to that session's
// chat. The chevron opens the sender's words under it, in muted body type. Several lines in a row
// fold into "Received N messages", which opens to them.
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import type { AcpmuxAgentMessage, AcpmuxRow } from "../model";
import "./receivedMessages.css";

export function ReceivedMessage({
  message,
  open,
  onToggle,
  onOpen,
}: {
  message: AcpmuxAgentMessage;
  open: boolean;
  onToggle(): void;
  onOpen(sessionId: string): void;
}) {
  const t = useT();
  // The sender keeps its place in the sentence in every language.
  const [before, after = ""] = t("offer.received", { title: "\u0000" }).split("\u0000");
  const { sessionId } = message;
  return (
    <div className="cv-received" data-open={open || undefined}>
      {/* The line toggles too; the sender link and the chevron are its keyboard stops. */}
      <div className="cv-received__line" onClick={onToggle}>
        {before}
        {sessionId ? (
          <button
            type="button"
            className="cv-received__sender"
            onClick={(event) => {
              event.stopPropagation();
              onOpen(sessionId);
            }}
          >
            {message.title}
          </button>
        ) : (
          <span className="cv-received__sender">{message.title}</span>
        )}
        {after}
        <button
          type="button"
          className="cv-received__chevron"
          aria-expanded={open}
          aria-label={t("received.show")}
          onClick={(event) => {
            event.stopPropagation();
            onToggle();
          }}
        >
          <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
        </button>
      </div>
      {open && <div className="cv-received__body selectable">{message.body}</div>}
    </div>
  );
}

/// "Received 3 messages ⌄": received lines folded together (receivedMessages.ts `groupReceived`).
export function ReceivedGroup({ row, open, onToggle }: { row: AcpmuxRow; open: boolean; onToggle(): void }) {
  const t = useT();
  return (
    <div className="cv-received">
      <button type="button" className="cv-received__line cv-received__group" aria-expanded={open} onClick={onToggle}>
        {t("received.group", { n: row.count ?? 0 })}
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
      </button>
    </div>
  );
}
