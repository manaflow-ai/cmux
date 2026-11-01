// Another agent's message to this chat (incomingMessage.ts): one quiet disclosure line among the
// tool rows where it arrived, never the person's bubble and never a card cut short (Leo,
// 2026-10-29: "why the fuck did you guys ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT
// WAS SAID TO SEE" ... "LEARN FROM CLAUDE CODE"). The line is the shared DisclosureRow
// (subagents/DisclosureRow.tsx): the sender's harness mark (a small bot when it has none), the
// sender's name, then the message's first line muted and cut to the line (messagePreview), and a
// chevron. A sub-session family's sender reads with who it is to this chat: "Parent ·
// coordinator". Opened, a light panel under the line holds the WHOLE message as Markdown (the line
// already names the sender, so the panel never says it again; Leo, 2026-10-29), PR, issue and file references linked, with the original prompt (cmux's or
// Claude Code's envelope) behind Details, its images, and the reply editor. Opening and closing hold
// the line on its pixel while the panel grows or shrinks under it (useAnchoredCollapse.ts: the
// transcript holds it, foldAnchor.ts). Whether it is open lasts while the page does
// (incomingOpened.ts), so the virtualized transcript keeps it, and the row estimator reads it; Find
// opens a message that holds its match without the hold, so Find can scroll to it.
// The sender's name is its own control at the line's start: a click opens the sender's chat beside
// this one, or its tab when one shows it (its id from the message, else the listed chat with its
// name), and its hover highlight is the name's alone, never the row's (Leo, 2026-10-29: "why the
// fuck do you even have this instead of just being able to click on the fucking name of the thing,
// the open chat? ... Just click the left name thing."). The rest of the line opens the message.
// The sender's mark is its harness's: the listed chat's, else the one the message names (a peer's
// relayed message, `fromHarness`), and a small bot when neither says, never a mark guessed from the
// sender's name (a Codex lane called `claude-…` drew Claude's; cmux#30247). Reply, at the line's end,
// answers in place: the answer goes to the sending chat in the message's thread
// (AcpmuxDirectClient.reply), from an editor in the panel. An open reply and its draft last while
// the page does; closing the message closes the reply and keeps the draft.
// The text is cleaner (Leo 2026-10-21: "just... idk make it all look nicer"): the sender's signature
// ("[lane] …") is dropped, a pull request written twice in a row shows once (messageRefs.ts), a
// commit SHA reads as quiet monospace, and a message from another machine names that machine's
// files, which draw with its name and a lock (chips/messageScope.ts).
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import type { PromptImage } from "../model";
import { messagePreview, unsigned, type IncomingMessage, type IncomingRelation } from "./incomingMessage";
import { dedupeReferences } from "./messageRefs";
import { PromptEditor, SentImages } from "./UserBubble";
import { FindReveal, foldFind } from "./chatFind";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { Bot, ChevronRight, TerminalSquare } from "./icons";
import { Markdown } from "./Markdown";
import { CardCopy } from "./CardCopy";
import { knownMark } from "../../shared/AgentMark";
import { useSenderChat, useSenderPlace } from "../subagents/subsessions";
import { AgentIdentity } from "../subagents/AgentIdentity";
import { agentTone } from "../subagents/agentTones";
import { useAgentAvatar } from "../agentAvatar";
import { useChiefFace } from "../chiefFace";
import { DisclosureRow } from "../subagents/DisclosureRow";
import { AgentTag } from "./AgentTag";
import "../subagents/AgentCard.css";
import { MessageScopeContext, type MessageScope } from "../chips/messageScope";
import { mentionedRepository } from "../../../githubReferences";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { laneNotice } from "./laneReport";
import "./LaneNoticeBatch.css";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { useTranscriptReadOnly } from "./readOnly";

/// A family sender's label, its relation before its name ("Parent · coordinator").
const RELATION_LABEL: Record<IncomingRelation, StringKey> = {
  parent: "message.from.parent",
  subsession: "message.from.subsession",
  ancestor: "message.from.ancestor",
  descendant: "message.from.descendant",
};

/// A harness logo's size in the sender's glyph slot (see SenderName).
const SENDER_LOGO_SIZE = 12;

/// The harness whose mark a sender draws: the listed chat's, else the one the message names (acpmux's
/// bound `fromHarness`), the first of them with a mark today, else that harness id itself, so a
/// profile icon that arrives later still replaces the fallback. Never one guessed from the sender's
/// name: a Codex lane called `claude-…` drew Claude's mark (cmux#30247). With neither, undefined,
/// and the line draws the neutral agent glyph.
export function senderHarness(listed: string | undefined, named: string | undefined): string | undefined {
  return knownMark(listed, named, listed ?? named);
}

/// The sender's mark alone (a received line's, an inbox group's): its avatar, a Chief's face, else
/// its harness's mark, else the neutral agent glyph in its own stable tone.
export function SenderMark({ message }: { message: IncomingMessage }) {
  const chief = useChiefFace(message.chief);
  const sender = useSenderChat(message.chief ? "" : message.name, message.sessionId);
  const avatar = useAgentAvatar(sender.sessionId);
  const harness = senderHarness(sender.harness, message.harness);
  const picture = message.chief ? chief?.src : avatar;
  return picture ? (
    <img className="cv-agent-avatar" src={picture} alt="" width={16} height={16} />
  ) : message.chief && chief?.text ? (
    <span className="cv-chief-text-avatar" aria-hidden="true">
      {chief.text}
    </span>
  ) : (
    // A sender with no harness mark keeps the robot in its own stable tone, so two such senders tell
    // apart. A logo fills its whole box while the envelope and the bot leave a margin in their 16px
    // one: at 12px its ink is the stroke glyphs' (about 12px), so a sender's logo and a send's
    // envelope read as one size in the shared glyph slot (transcript-icon-column.test.ts).
    <AgentIdentity
      harness={harness}
      tone={agentTone(sender.sessionId ?? message.sessionId ?? message.name)}
      size={SENDER_LOGO_SIZE}
      fallbackNode={<Bot size={16} />}
    />
  );
}

/// The sender's mark and name at a received line's start (and a waiting group's sender head,
/// PendingMessagesCard.tsx): the name opens the sender's chat when there is one to open.
export function SenderName({ message, onOpen }: { message: IncomingMessage; onOpen(sessionId: string): void }) {
  const t = useT();
  // A Chief's message names the Chief and draws its avatar (chiefFace.ts); its turn session is no
  // chat of the list, so no listed chat with its name stands in for it, and it is no chat to open.
  const chief = useChiefFace(message.chief);
  const name = (message.chief && chief?.name) || message.name;
  const sender = useSenderChat(message.chief ? "" : message.name, message.sessionId);
  // Read only (a guest): the sender's chat is not this reader's to open.
  const readOnly = useTranscriptReadOnly();
  const sessionId = message.chief || readOnly ? undefined : sender.sessionId;
  const notice = laneNotice(message);
  const inboxNames =
    notice?.kind === "inbox"
      ? [...new Set((notice.threads ?? []).map(({ sender }) => sender).filter(Boolean))].join(", ")
      : "";
  const from = inboxNames || (message.relation ? t(RELATION_LABEL[message.relation], { name }) : name);
  const icon = <SenderMark message={message} />;
  // "Open chief-ui (huge-blue)": the chat the name opens, and the other machine it runs on.
  const openTitle = sender.host
    ? t("subagents.openOnHost", { name, host: sender.host })
    : t("subagents.open", { name });
  return (
    // Its own part of the line: the name opens the sender's chat or nothing, never the message.
    <span className="cv-received__sender" data-own-click="">
      <span className="cv-received__mark" aria-hidden="true">
        {icon}
      </span>
      {sessionId ? (
        <AgentTag
          name={from}
          className="cv-received__from cv-received__from--open"
          title={openTitle}
          ariaLabel={openTitle}
          onClick={() => onOpen(sessionId)}
        />
      ) : (
        <AgentTag name={from} className="cv-received__from" />
      )}
    </span>
  );
}

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
  /// The message's hover row (MessageActions.tsx ReceivedActions) and its queue tag, at the line's end.
  actions?: ReactNode;
  /// The repository a bare `#123` in the message names (MessageRow's).
  githubRepository?: string;
}) {
  const t = useT();
  // Read only (a guest): nobody replies.
  const readOnly = useTranscriptReadOnly();
  const notice = laneNotice(message);
  const session = useContext(PromptMarksSession);
  const key = `${session ?? ""}\u0000${id}`;
  // Whether the person opened it lasts while the page does (incomingOpened.ts), and the row
  // estimator reads it.
  const [open, setOpen] = useState(() => messageOpened(session, id));
  const show = (next: boolean) => {
    setMessageOpened(session, id, next);
    setOpen(next);
  };
  const rawId = useId();
  // The prompt as the agent got it (cmux's envelope around the message) waits behind Details, open
  // or closed per chat and row, so scrolling it out of the virtualized transcript keeps it.
  const [details, setDetails] = useTranscriptDisclosure(`message-details:${id}`);
  // Only the reader's own clicks play the motion; Find opening a message for its match does not.
  const played = useRef(false);
  const envelope = useAnchoredCollapse({
    open: details,
    onOpenChange: setDetails,
    animates: () => !notice && played.current,
    fadeIn: false,
  });
  // Find in Chat opens a closed message that holds its match, as a folded thought opens; a match
  // only in the envelope (Find searches the whole prompt) opens Details too.
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === id ? reveal.needle : "";
  const inText = Boolean(needle && foldFind(notice?.body ?? unsigned(message.text, message.name)).includes(needle));
  const inRaw = Boolean(needle && !inText && foldFind(message.raw).includes(needle));
  useLayoutEffect(() => {
    if (!inText && !inRaw) return;
    played.current = false;
    show(true);
    if (inRaw) setDetails(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [inText, inRaw, reveal]);
  const raw = notice?.details ?? (message.raw.trim() === message.text ? undefined : message.raw);
  // A Chief's message names the Chief (chiefFace.ts): its name and avatar as the sidebar shows them.
  // Its turn session is no chat of the list, so no listed chat with its name stands in for it.
  const chief = useChiefFace(message.chief);
  const name = (message.chief && chief?.name) || message.name;
  const sender = useSenderChat(message.chief ? "" : message.name, message.sessionId);
  const place = useSenderPlace(sender.sessionId);
  // The sender's words without a signature that only repeats its name (incomingMessage.ts reads
  // it on every path; a record from before that, or a queued one, may still have it).
  const text = notice?.body ?? unsigned(message.text, message.name);
  // The machine the sender's files are on, when it is another (a peer's relayed message names none).
  const host = message.remote ? (place?.host ?? "") : place?.host;
  const repository = githubRepository ?? mentionedRepository(text);
  const body = useMemo(() => dedupeReferences(text, repository), [text, repository]);
  const scope = useMemo<MessageScope>(() => (host === undefined ? {} : { host }), [host]);
  const preview = useMemo(() => notice?.preview ?? messagePreview(body), [body, notice]);
  // A sub-session family's sender says who it is to this chat.
  const from = message.relation ? t(RELATION_LABEL[message.relation], { name }) : name;
  // A reply needs a chat to go to and the message's id to answer: acpmux's `agent_message`.
  const replies = !readOnly && onReply !== undefined && message.sessionId !== undefined && message.msgId !== undefined;
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
    played.current = true;
    setFocusEditor(true);
    show(true);
    setReply("open");
  };
  // The reader's toggle plays the fold; closing the message closes its reply too, draft kept.
  const toggled = (next: boolean) => {
    played.current = true;
    if (!next && editing) setReply("closed");
    show(next);
  };
  return (
    <DisclosureRow
      className={notice ? "cv-received cv-lane-notice" : "cv-received"}
      open={open}
      onOpenChange={toggled}
      animates={() => !notice && played.current}
      leading={<SenderName message={message} onOpen={onOpen} />}
      lineClassName="cv-agent-activity-row"
      toggleLabel={t("message.collapsedLabel", { from, preview: preview || t("message.noText") })}
      label={
        // Find counts the panel's whole text, not the line's first-line copy of it.
        <span className="cv-received__preview" data-find-skip="">
          {preview || t("message.noText")}
        </span>
      }
      // It opens at once, its height alone moving, as the message's card always did; closing fades.
      fadeIn={false}
      // One slot at the line's end, over the preview's tail, shown on hover or focus: it never moves
      // the chevron, which ends every message's line at the same place (conversation.css).
      actions={
        <span className="cv-received__hover">
          {replies && !editing && (
            <button ref={replyButton} type="button" className="cv-received__reply" onClick={startReply}>
              {t("message.reply")}
            </button>
          )}
          {actions}
        </span>
      }
    >
      {/* The sender's words, as written, from the card's corner. */}
      <CardCopy text={text} />
      {/* The chips read whose files these are (chips/messageScope.ts). */}
      <MessageScopeContext.Provider value={scope}>
        <div className="cv-received__text selectable">
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
      {images && images.length > 0 && <SentImages images={images} className="cv-message__images" />}
      {raw !== undefined && (
        <div className="cv-received__details">
          <button
            ref={envelope.headerRef}
            type="button"
            className="cv-received__more"
            aria-expanded={details}
            aria-controls={details ? rawId : undefined}
            onClick={() => {
              played.current = true;
              envelope.toggle();
            }}
          >
            {t("message.details")}
            <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${details ? " is-open" : ""}`} />
          </button>
          {envelope.present && (
            <div id={rawId} {...envelope.bodyProps}>
              <pre className="cv-tool-output selectable">{raw}</pre>
            </div>
          )}
        </div>
      )}
      {replies && editing && (
        <div className="cv-message__reply">
          <PromptEditor
            initial={replyDrafts.get(key) ?? ""}
            canSend
            label={t("message.replyTo", { name })}
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
      {reply === "sent" && <output className="cv-message__note cv-received__replied">{t("message.replied")}</output>}
    </DisclosureRow>
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
