// Another agent's message to this chat (incomingMessage.ts) as MessageCard draws one this agent
// sent: sender to this agent, the message's first two lines, and the whole message once opened.
// Opened, a Claude Code envelope also shows the prompt as the agent got it; a sender that is a
// chat here opens beside this one. Reply (R, with the card focused) answers in place: the answer
// goes to the sending chat in the message's thread (AcpmuxDirectClient.reply).
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { IncomingMessage } from "./incomingMessage";
import { PromptEditor } from "./UserBubble";
import { ArrowRight, ChevronDown, ChevronRight, Envelope, TerminalSquare } from "./icons";

export function IncomingMessageCard({
  message,
  onOpen,
  onReply,
}: {
  message: IncomingMessage;
  onOpen(sessionId: string): void;
  /// Sends a reply to the message's sender; rejects when it was not sent.
  onReply?(message: IncomingMessage, text: string): Promise<void>;
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
  // A reply needs a chat to go to and the message's id to answer: acpmux's `agent_message`.
  const replies = onReply !== undefined && sessionId !== undefined && message.msgId !== undefined;
  const [reply, setReply] = useState<"closed" | "open" | "sent" | "failed">("closed");
  const [draft, setDraft] = useState("");
  const card = useRef<HTMLDivElement>(null);
  const replyButton = useRef<HTMLButtonElement>(null);
  const closeReply = (next: "closed" | "sent") => {
    setReply(next);
    // The editor unmounts with the focus in it: the Reply button takes it back.
    requestAnimationFrame(() => replyButton.current?.focus());
  };
  // R on the focused card opens the reply; typing in its editor is text. Native, as QuestionCard
  // and PermissionCard listen: the card is a group, not a control of its own.
  useEffect(() => {
    const element = card.current;
    if (!element || !replies) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
      if (event.key.toLowerCase() !== "r" || event.repeat) return;
      if ((event.target as HTMLElement).closest("textarea, input")) return;
      event.preventDefault();
      setReply("open");
    };
    // ui-allow: the card's one action key (R: Reply), as PermissionCard's and QuestionCard's keys.
    element.addEventListener("keydown", onKeyDown);
    return () => element.removeEventListener("keydown", onKeyDown);
  }, [replies]);
  const editing = reply === "open" || reply === "failed";
  return (
    <div ref={card} className="cv-message is-incoming">
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
      {(long || raw !== undefined || sessionId || replies) && (
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
          {replies && !editing && (
            <button
              ref={replyButton}
              type="button"
              className="cv-message__more"
              aria-label={t("message.reply")}
              aria-keyshortcuts="R"
              onClick={() => setReply("open")}
            >
              {t("message.reply")}
              <kbd className="cv-message__key">R</kbd>
            </button>
          )}
          {reply === "sent" && <span className="cv-message__note">{t("message.replied")}</span>}
        </div>
      )}
      {replies && editing && (
        <div className="cv-message__reply">
          <PromptEditor
            initial={draft}
            canSend
            label={t("message.replyTo", { name: message.name })}
            onCancel={() => closeReply("closed")}
            onSend={async (text) => {
              setDraft(text);
              if (!onReply) return;
              try {
                await onReply(message, text);
                setDraft("");
                closeReply("sent");
              } catch {
                setReply("failed");
              }
            }}
          />
          {reply === "failed" && (
            <output className="cv-message__note is-failed">{t("message.replyFailed")}</output>
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
