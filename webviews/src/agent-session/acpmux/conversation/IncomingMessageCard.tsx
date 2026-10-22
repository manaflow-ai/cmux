// Another agent's message to this chat (incomingMessage.ts): one left-aligned line among the tool
// rows, never the person's bubble and never folded away. The line is the sender's harness mark (a
// small bot when it has none), the sender's name as a chip, and the message's first line as a
// preview; the chip opens the sender's chat beside this one (its id from the message, else the
// listed chat with its name), and the rest of the line opens the message under it as a glass card,
// its text drawn as Markdown with PR, issue and file references linked. The prompt as the agent got
// it (cmux's or Claude Code's envelope) waits behind Details under the card. Whether it is open
// lasts while the page does, so scrolling it out of the virtualized transcript keeps it. A
// sub-session family's sender reads with who it is to this chat: "Parent · coordinator". Reply, at
// the line's end, answers in place: the answer goes to the sending chat in the message's thread
// (AcpmuxDirectClient.reply), from an editor under the card. An open reply and its draft last
// while the page does too; closing the message closes the reply and keeps the draft.
import { useContext, useId, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import type { PromptImage } from "../model";
import { messagePreview, type IncomingMessage, type IncomingRelation } from "./incomingMessage";
import { PromptEditor, SentImages } from "./UserBubble";
import { FindReveal } from "./chatFind";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { Bot, ChevronRight, TerminalSquare } from "./icons";
import { Markdown } from "./Markdown";
import { AgentMark, agentBrand } from "../../shared/AgentMark";
import { useSenderChat } from "../subagents/subsessions";

/// A family sender's label, its relation before its name ("Parent · coordinator").
const RELATION_LABEL: Record<IncomingRelation, StringKey> = {
  parent: "message.from.parent",
  subsession: "message.from.subsession",
  ancestor: "message.from.ancestor",
  descendant: "message.from.descendant",
};

/// The messages the person opened, by chat and row (row ids repeat across chats).
const opened = new Set<string>();
/// The messages whose reply is open, and the reply drafts, by the same key.
const replying = new Set<string>();
const replyDrafts = new Map<string, string>();

export function IncomingMessageLine({
  id,
  message,
  images,
  onOpen,
  onReply,
  actions,
  githubRepository,
}: {
  /// The row's id, which keeps the line open across remounts.
  id: string;
  message: IncomingMessage;
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  onOpen(sessionId: string): void;
  /// Sends a reply to the message's sender; rejects when it was not sent.
  onReply?(message: IncomingMessage, text: string): Promise<void>;
  /// The message's hover row (MessageActions.tsx ReceivedActions), at the line's end.
  actions?: ReactNode;
  /// The repository a bare `#123` in the message names (MessageRow's).
  githubRepository?: string;
}) {
  const t = useT();
  const key = `${useContext(PromptMarksSession) ?? ""}\u0000${id}`;
  const [open, setOpen] = useState(() => opened.has(key));
  const show = (next: boolean) => {
    if (next) opened.add(key);
    else opened.delete(key);
    setOpen(next);
  };
  const toggleButton = useRef<HTMLButtonElement>(null);
  const bodyId = useId();
  const rawId = useId();
  // The prompt as the agent got it (cmux's envelope around the message) waits behind Details.
  const [details, setDetails] = useState(false);
  // Find in Chat opens a closed message that holds its match, as a folded thought opens; a match
  // only in the envelope (Find searches the whole prompt) opens Details too.
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === id ? reveal.needle : "";
  const inText = Boolean(needle && message.text.toLocaleLowerCase().includes(needle));
  const inRaw = Boolean(needle && !inText && message.raw.toLocaleLowerCase().includes(needle));
  useLayoutEffect(() => {
    if (!inText && !inRaw) return;
    show(true);
    if (inRaw) setDetails(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [inText, inRaw, reveal]);
  const raw = message.raw.trim() === message.text ? undefined : message.raw;
  const sender = useSenderChat(message.name, message.sessionId);
  const sessionId = sender.sessionId;
  const preview = messagePreview(message.text);
  // A sub-session family's sender says who it is to this chat.
  const from = message.relation ? t(RELATION_LABEL[message.relation], { name: message.name }) : message.name;
  const label = t("message.label", { from, to: t("message.self") });
  // A reply needs a chat to go to and the message's id to answer: acpmux's `agent_message`.
  const replies = onReply !== undefined && message.sessionId !== undefined && message.msgId !== undefined;
  const [reply, setReplyState] = useState<"closed" | "open" | "sent" | "failed">(() =>
    replying.has(key) ? "open" : "closed",
  );
  const setReply = (next: typeof reply) => {
    if (next === "open" || next === "failed") replying.add(key);
    else replying.delete(key);
    setReplyState(next);
  };
  const replyButton = useRef<HTMLButtonElement>(null);
  // The editor takes the focus when the person opens it, not when the row draws again.
  const [focusEditor, setFocusEditor] = useState(false);
  const closeReply = (next: "closed" | "sent") => {
    setReply(next);
    // The editor unmounts with the focus in it: the Reply button takes it back.
    requestAnimationFrame(() => replyButton.current?.focus());
  };
  const editing = reply === "open" || reply === "failed";
  // Reply opens the message too, so the editor sits under what it answers.
  const startReply = () => {
    setFocusEditor(true);
    show(true);
    setReply("open");
  };
  // Closing the message closes its reply too, draft kept; the focus goes to the chevron, so it
  // is not lost with the editor.
  const toggle = () => {
    if (open && editing) {
      setReply("closed");
      requestAnimationFrame(() => toggleButton.current?.focus());
    }
    show(!open);
  };
  return (
    <div className="cv-received" data-open={open || undefined}>
      <div className="cv-received__line">
        <span className="cv-received__icon">
          {agentBrand(sender.harness) ? <AgentMark agent={sender.harness} size={14} /> : <Bot size={16} />}
        </span>
        {sessionId ? (
          <button
            type="button"
            className="cv-received__name"
            aria-label={t("subagents.open", { name: message.name })}
            onClick={() => onOpen(sessionId)}
          >
            {from}
          </button>
        ) : (
          <span className="cv-received__name is-plain" aria-hidden onClick={toggle}>
            {from}
          </span>
        )}
        {/* The preview and its chevron open the message; the label reads the line. */}
        <button
          ref={toggleButton}
          type="button"
          className="cv-received__toggle"
          aria-expanded={open}
          aria-controls={open ? bodyId : undefined}
          aria-label={label}
          onClick={toggle}
        >
          <span className="cv-received__preview">{open ? "" : preview}</span>
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
        </button>
        {replies && !editing && (
          <button ref={replyButton} type="button" className="cv-received__reply" onClick={startReply}>
            {t("message.reply")}
          </button>
        )}
        {actions}
      </div>
      {open && (
        <div id={bodyId} className="cv-received__body selectable">
          {message.text ? <Markdown githubRepository={githubRepository}>{message.text}</Markdown> : t("message.noText")}
        </div>
      )}
      {open && raw !== undefined && (
        <div className="cv-received__details">
          <button
            type="button"
            className="cv-received__more"
            aria-expanded={details}
            aria-controls={details ? rawId : undefined}
            onClick={() => setDetails((value) => !value)}
          >
            {t("message.details")}
            <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${details ? " is-open" : ""}`} />
          </button>
          {details && (
            <pre id={rawId} className="cv-tool-output selectable">
              {raw}
            </pre>
          )}
        </div>
      )}
      {open && replies && editing && (
        <div className="cv-message__reply">
          <PromptEditor
            initial={replyDrafts.get(key) ?? ""}
            canSend
            label={t("message.replyTo", { name: message.name })}
            // UserBubble's own prop, which takes focus through a ref when the editor mounts, not
            // the DOM attribute the rule is about: the reader opened this reply editor with a
            // click and types into it next.
            // oxlint-disable-next-line jsx-a11y/no-autofocus
            autoFocus={focusEditor}
            onChange={(text) => {
              if (text) replyDrafts.set(key, text);
              else replyDrafts.delete(key);
            }}
            // Cancel drops the draft; closing the message keeps it.
            onCancel={() => {
              replyDrafts.delete(key);
              closeReply("closed");
            }}
            onSend={async (text) => {
              if (!onReply) return;
              try {
                await onReply(message, text);
                replyDrafts.delete(key);
                closeReply("sent");
              } catch {
                setReply("failed");
              }
            }}
          />
          {reply === "failed" && <output className="cv-message__note is-failed">{t("message.replyFailed")}</output>}
        </div>
      )}
      {open && reply === "sent" && (
        <output className="cv-message__note cv-received__replied">{t("message.replied")}</output>
      )}
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
