// Another agent's message to this chat (incomingMessage.ts): one left-aligned line among the tool
// rows, never the person's bubble, with the message under it. The line is the sender's harness mark
// (a small bot when it has none) and the sender's name as a chip, which opens the sender's chat
// beside this one, or its tab when one shows it (its id from the message, else the listed chat with
// its name, a chat on another machine by its bare name too; Leo, ask-7325396234: "I THINK I WANNA
// BE ABLE TO CLICK ON THESE TO ACTUALLY GO TO THEM"), its tooltip naming the chat and that machine
// ("Open chief-ui (huge-blue)"). The message is a
// compact line in both display modes. The line expands its unboxed Markdown, with PR, issue and
// file references linked, and the original prompt
// (cmux's or Claude Code's envelope) behind Details under it. Whether it is open lasts while the
// page does, so scrolling it out of the virtualized transcript keeps it. A sub-session family's
// sender reads with who it is to this chat: "Parent · coordinator". Reply, at the line's end,
// answers in place: the answer goes to the sending chat in the message's thread
// (AcpmuxDirectClient.reply), from an editor under the card. An open reply and its draft last
// while the page does too; closing the message closes the reply and keeps the draft.
// The card is cleaner (Leo 2026-10-21: "just... idk make it all look nicer"): the sender's signature
// ("[lane] …") is dropped, a pull request written twice in a row shows once (messageRefs.ts), a
// commit SHA reads as quiet monospace, and a message from another machine names that machine's
// files, which draw with its name and a lock (chips/messageScope.ts).
// A received message starts as one line in both display modes (Leo, 2026-10-26: "minimized from
// the start. Just one line"). The existing anchored fold expands the full Markdown under that
// line, which stays on its pixel. Reply opens without anchoring so the editor stays visible.
// Only the reader's clicks play motion; Find opens a match instantly.
import { useCallback, useContext, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import type { PromptImage } from "../model";
import { messagePreview, unsigned, type IncomingMessage, type IncomingRelation } from "./incomingMessage";
import { dedupeReferences } from "./messageRefs";
import { PromptEditor, SentImages } from "./UserBubble";
import { FindReveal } from "./chatFind";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { Bot, ChevronRight, TerminalSquare } from "./icons";
import { Markdown } from "./Markdown";
import { AgentMark } from "../../shared/AgentMark";
import { useSenderChat, useSenderPlace } from "../subagents/subsessions";
import { useAgentAvatar } from "../agentAvatar";
import "../subagents/AgentCard.css";
import { MessageScopeContext, type MessageScope } from "../chips/messageScope";
import { mentionedRepository } from "../../../githubReferences";
import { useChatDisplay } from "../chatDisplay";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { messageOpened, setMessageOpened } from "./incomingOpened";

/// A family sender's label, its relation before its name ("Parent · coordinator").
const RELATION_LABEL: Record<IncomingRelation, StringKey> = {
  parent: "message.from.parent",
  subsession: "message.from.subsession",
  ancestor: "message.from.ancestor",
  descendant: "message.from.descendant",
};

/// The messages whose reply is open, and the reply drafts, by the same key.
const replying = new Set<string>();
const replyDrafts = new Map<string, string>();

export function IncomingMessageLine({
  id,
  message,
  messageAt,
  images,
  onOpen,
  onReply,
  status,
  actions,
  githubRepository,
}: {
  /// The row's id, which keeps the line open across remounts.
  id: string;
  message: IncomingMessage;
  /// The containing transcript row's epoch timestamp, used to date bare UTC times.
  messageAt?: number;
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  /// Opens the sender's chat by its acpmux id (App.tsx `openSenderChat`, `chat.offer.open` with `sender`).
  onOpen(sessionId: string): void;
  /// Sends a reply to the message's sender; rejects when it was not sent.
  onReply?(message: IncomingMessage, text: string): Promise<void>;
  /// A quiet delivery label, independent of the hover actions.
  status?: ReactNode;
  /// The message's hover row (MessageActions.tsx ReceivedActions), at the line's end.
  actions?: ReactNode;
  /// The repository a bare `#123` in the message names (MessageRow's).
  githubRepository?: string;
}) {
  const t = useT();
  const session = useContext(PromptMarksSession);
  const key = `${session ?? ""}\u0000${id}`;
  // Whether the person opened it lasts while the page does (incomingOpened.ts), and the row
  // estimator reads it.
  const [open, setOpen] = useState(() => messageOpened(session, id));
  const show = (next: boolean) => {
    setMessageOpened(session, id, next);
    setOpen(next);
  };
  const toggleButton = useRef<HTMLButtonElement>(null);
  const bodyId = useId();
  const rawId = useId();
  // The prompt as the agent got it (cmux's envelope around the message) waits behind Details.
  const [details, setDetails] = useState(false);
  // Only the reader's own clicks play the motion; Find opening a message for its match does not.
  const played = useRef(false);
  // cmux's Minimal Mode, which the chat follows (chatDisplay.ts).
  const { minimal } = useChatDisplay();
  // Out of Minimal Mode, Details folds its envelope in and out; in it, Details shows it at once (#25002).
  const envelope = useAnchoredCollapse({
    open: details,
    onOpenChange: setDetails,
    animates: () => played.current && !minimal,
  });
  // Find in Chat opens a closed message that holds its match, as a folded thought opens; a match
  // only in the envelope (Find searches the whole prompt) opens Details too.
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === id ? reveal.needle : "";
  const inText = Boolean(needle && unsigned(message.text, message.name).toLocaleLowerCase().includes(needle));
  const inRaw = Boolean(needle && !inText && message.raw.toLocaleLowerCase().includes(needle));
  useLayoutEffect(() => {
    if (!inText && !inRaw) return;
    played.current = false;
    show(true);
    if (inRaw) setDetails(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [inText, inRaw, reveal]);
  const raw = message.raw.trim() === message.text ? undefined : message.raw;
  const sender = useSenderChat(message.name, message.sessionId);
  const sessionId = sender.sessionId;
  const place = useSenderPlace(sessionId);
  const avatar = useAgentAvatar(sessionId);
  // The sender's words without a signature that only repeats its name (incomingMessage.ts reads
  // it on every path; a record from before that, or a queued one, may still have it).
  const text = unsigned(message.text, message.name);
  // The machine the sender's files are on, when it is another (a peer's relayed message names none).
  const host = message.remote ? (place?.host ?? "") : place?.host;
  const repository = githubRepository ?? mentionedRepository(text);
  const body = useMemo(() => dedupeReferences(text, repository), [text, repository]);
  const scope = useMemo<MessageScope>(() => (host === undefined ? {} : { host }), [host]);
  // Closed is always one line. The existing anchored fold holds that line still while the reader
  // opens the full Markdown; Find reveals without motion. No measurement of hidden text is needed.
  const collapse = useAnchoredCollapse({ open, onOpenChange: show, animates: () => played.current, fadeIn: false });
  const header = collapse.headerRef;
  const toggleRef = useCallback(
    (node: HTMLButtonElement | null) => {
      toggleButton.current = node;
      header(node);
    },
    [header],
  );
  const folded = !open;
  const preview = useMemo(() => messagePreview(body), [body]);
  // A reader's click: the motion plays, a drawn card resizing from its height now.
  const byReader = () => {
    played.current = true;
  };
  // "Open chief-ui (huge-blue)": the chat the chip opens, and the other machine it runs on.
  const openLabel = sender.host
    ? t("subagents.openOnHost", { name: message.name, host: sender.host })
    : t("subagents.open", { name: message.name });
  // A sub-session family's sender says who it is to this chat.
  const from = message.relation ? t(RELATION_LABEL[message.relation], { name: message.name }) : message.name;
  const label = folded
    ? t("message.collapsedLabel", { from, preview: preview || t("message.noText") })
    : t("message.label", { from, to: t("message.self") });
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
  // It opens without holding the line: the reader asked to type, so the view follows the editor
  // rather than keeping the line, which left a long message's editor below the view.
  const startReply = () => {
    byReader();
    setFocusEditor(true);
    show(true);
    setReply("open");
  };
  // Closing the message closes its reply too, draft kept; the focus goes to the chevron, so it
  // is not lost with the editor.
  const toggle = () => {
    byReader();
    if (open && editing) {
      setReply("closed");
      requestAnimationFrame(() => toggleButton.current?.focus());
    }
    // The line stays where it is drawn while the card opens or closes under it.
    collapse.setOpen(!open);
  };
  // Full, selectable Markdown under the sender line, without a second bubble around it.
  const card = (
    <div id={bodyId} className="cv-received__body selectable">
      {/* The chips read whose files these are (chips/messageScope.ts). */}
      <MessageScopeContext.Provider value={scope}>
        <div className="cv-received__text">
          {text ? (
            <Markdown
              githubRepository={repository}
              commits="quiet"
              thumbnails={host === undefined}
              messageAt={messageAt}
            >
              {body}
            </Markdown>
          ) : (
            t("message.noText")
          )}
        </div>
      </MessageScopeContext.Provider>
    </div>
  );
  // Details and the envelope under it. Out of Minimal Mode its row is the card's fold, there only
  // while the card is open (and closing).
  const detailsRow = (
    <div className="cv-received__details">
      <button
        ref={minimal ? undefined : envelope.headerRef}
        type="button"
        className="cv-received__more"
        aria-expanded={details}
        aria-controls={details ? rawId : undefined}
        onClick={() => {
          // Minimal Mode's Details opens and closes at once, as it did (#25002).
          if (minimal) {
            setDetails((value) => !value);
            return;
          }
          played.current = true;
          envelope.toggle();
        }}
      >
        {t("message.details")}
        <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${details ? " is-open" : ""}`} />
      </button>
      {minimal
        ? details && (
            <pre id={rawId} className="cv-tool-output selectable">
              {raw}
            </pre>
          )
        : envelope.present && (
            <div {...envelope.bodyProps}>
              <pre id={rawId} className="cv-tool-output selectable">
                {raw}
              </pre>
            </div>
          )}
    </div>
  );
  return (
    <div className="cv-received" data-open={open || undefined} data-minimal={minimal || undefined}>
      <div className="cv-received__line">
        <span className="cv-received__icon">
          {avatar ? (
            <img className="cv-agent-avatar" src={avatar} alt="" width={16} height={16} />
          ) : (
            <AgentMark agent={sender.harness} size={14} fallback={<Bot size={16} />} />
          )}
        </span>
        {sessionId ? (
          <button
            type="button"
            className="cv-received__name"
            aria-label={openLabel}
            title={openLabel}
            onClick={() => onOpen(sessionId)}
          >
            {from}
          </button>
        ) : (
          <span className="cv-received__name is-plain" aria-hidden onClick={toggle}>
            {from}
          </span>
        )}
        {/* The rest of the line opens the message; the label reads the line. Its chevron shows when
            opening shows more: a cut message's rest, or Details. */}
        <button
          ref={toggleRef}
          type="button"
          className="cv-received__toggle"
          aria-expanded={open}
          aria-controls={collapse.present ? bodyId : undefined}
          aria-label={label}
          onClick={toggle}
        >
          {folded && <span className="cv-received__preview">{preview || t("message.noText")}</span>}
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
        </button>
        {replies && !editing && (
          <button ref={replyButton} type="button" className="cv-received__reply" onClick={startReply}>
            {t("message.reply")}
          </button>
        )}
        {status && (
          <span className="cv-received__queued" title={typeof status === "string" ? status : undefined}>
            {status}
          </span>
        )}
        {actions}
      </div>
      {collapse.present && (
        <div {...collapse.bodyProps}>
          {card}
          {raw !== undefined && detailsRow}
        </div>
      )}
      {replies && editing && (
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
      {!folded && reply === "sent" && (
        <output className="cv-message__note cv-received__replied">{t("message.replied")}</output>
      )}
      {!folded && images && images.length > 0 && <SentImages images={images} className="cv-message__images" />}
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
