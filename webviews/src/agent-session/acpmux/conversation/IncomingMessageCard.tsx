// Another agent's message to this chat (incomingMessage.ts) as Claude desktop draws one: a quiet
// line, "Received message from <sender> ›", never the person's bubble and never folded away. The
// sender's name opens its chat beside this one when it is a chat here; › opens the message under
// the line (and, for a Claude Code envelope, the prompt as the agent got it). Whether it is open
// lasts while the page does, so scrolling it out of the virtualized transcript keeps it. Reply (R, with
// the line focused) answers in place: the answer goes to the sending chat in the message's thread
// (AcpmuxDirectClient.reply).
import { useContext, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { PromptImage } from "../model";
import type { IncomingMessage } from "./incomingMessage";
import { PromptEditor } from "./UserBubble";
import { SentImages } from "./UserBubble";
import { FindReveal } from "./chatFind";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { ChevronRight, TerminalSquare } from "./icons";

/// The messages the person opened, by chat and row (row ids repeat across chats).
const opened = new Set<string>();

export function IncomingMessageLine({
  id,
  message,
  images,
  onOpen,
  onReply,
}: {
  /// The row's id, which keeps the line open across remounts.
  id: string;
  message: IncomingMessage;
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  onOpen(sessionId: string): void;
  /// Sends a reply to the message's sender; rejects when it was not sent.
  onReply?(message: IncomingMessage, text: string): Promise<void>;
}) {
  const t = useT();
  const key = `${useContext(PromptMarksSession) ?? ""}\u0000${id}`;
  const [open, setOpen] = useState(() => opened.has(key));
  const show = (next: boolean) => {
    if (next) opened.add(key);
    else opened.delete(key);
    setOpen(next);
  };
  const toggle = () => show(!open);
  // Find in Chat opens a closed message that holds its match, as a folded thought opens.
  const reveal = useContext(FindReveal);
  const hit = Boolean(
    reveal && reveal.rowId === id && reveal.needle && message.text.toLocaleLowerCase().includes(reveal.needle),
  );
  useLayoutEffect(() => {
    if (!hit) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
  const bodyId = useId();
  // The name sits where the sentence puts it ("Received message from {title}").
  const [before, after = ""] = t("offer.received", { title: "\u0000" }).split("\u0000");
  const raw = message.raw.trim() === message.text ? undefined : message.raw;
  const sessionId = message.sessionId;
  // A reply needs a chat to go to and the message's id to answer: acpmux's `agent_message`.
  const replies = onReply !== undefined && sessionId !== undefined && message.msgId !== undefined;
  const [reply, setReply] = useState<"closed" | "open" | "sent" | "failed">("closed");
  const [draft, setDraft] = useState("");
  const line = useRef<HTMLDivElement>(null);
  const replyButton = useRef<HTMLButtonElement>(null);
  const closeReply = (next: "closed" | "sent") => {
    setReply(next);
    // The editor unmounts with the focus in it: the Reply button takes it back.
    requestAnimationFrame(() => replyButton.current?.focus());
  };
  // R in the focused line opens the reply; typing in its editor is text. Native, as QuestionCard
  // and PermissionCard listen: the line is a group, not a control of its own.
  useEffect(() => {
    const element = line.current;
    if (!element || !replies) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
      if (event.key.toLowerCase() !== "r" || event.repeat) return;
      if ((event.target as HTMLElement).closest("textarea, input")) return;
      event.preventDefault();
      setReply("open");
    };
    // ui-allow: the line's one action key (R: Reply), as PermissionCard's and QuestionCard's keys.
    element.addEventListener("keydown", onKeyDown);
    return () => element.removeEventListener("keydown", onKeyDown);
  }, [replies]);
  const editing = reply === "open" || reply === "failed";
  const label = t("message.label", { from: message.name, to: t("message.self") });
  return (
    <div ref={line} className="cv-received" data-open={open || undefined}>
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
          aria-controls={open ? bodyId : undefined}
          aria-label={label}
          onClick={toggle}
        >
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
        </button>
        {replies && !editing && (
          <button
            ref={replyButton}
            type="button"
            className="cv-received__reply"
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
      {open && (
        <div id={bodyId} className="cv-received__body selectable">
          {message.text || t("message.noText")}
        </div>
      )}
      {open && raw !== undefined && <pre className="cv-tool-output selectable">{raw}</pre>}
      {images && images.length > 0 && <SentImages images={images} className="cv-message__images" />}
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
          {reply === "failed" && <output className="cv-message__note is-failed">{t("message.replyFailed")}</output>}
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
