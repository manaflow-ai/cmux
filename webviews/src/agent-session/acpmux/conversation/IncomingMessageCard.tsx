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
// A sender on another machine names that machine after its name, muted ("review-lane ·
// studio-mac"), so a lane's message never reads as this Mac's own.
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
import { useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useT, type StringKey } from "../i18n";
import type { PromptImage } from "../model";
import { messagePreview, unsigned, type IncomingMessage, type IncomingRelation } from "./incomingMessage";
import { dedupeReferences } from "./messageRefs";
import { PromptEditor, SentImages, SentVideoTiles } from "./UserBubble";
import type { SentVideo } from "./sentVideos";
import { FindReveal, foldFind } from "./chatFind";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { Bot, ChevronRight, TerminalSquare } from "./icons";
import { Markdown } from "./Markdown";
import { CardCopy } from "./CardCopy";
import { ClampedText } from "./ClampedText";
import { useReceivedLook } from "./receivedLook";
import { hasAgentMark, MonogramMark } from "../../shared/AgentMark";
import { useMachineChats, useSenderChat, useSenderIdentity, useSenderPlace } from "../subagents/subsessions";
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup, MenuSeparator } from "../../../ui/Menu";
import { copyTextResult } from "./clipboard";
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
import "./AgentMessageRow.css";
import "./LaneNoticeBatch.css";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { useTranscriptReadOnly } from "./readOnly";
import { Face } from "../multiplayer/Faces";
import { FileAttachment, type FileAttachmentInfo } from "../FileAttachment";
import { isGuest, type Participant } from "../multiplayer/participants";
import { useMessageLineLook } from "./messageLineLook";
import type { AgentNotice } from "./agentNotice";
import { NoticeMark } from "./NoticeMark";
import { SEVERITY_LABEL } from "./noticeMarkModel";
import { noticeMarkdown, titleParts } from "./agentNotice";
import { useNoticeLook, type NoticeLook } from "./noticeLook";
import { openSessionAttributes } from "./menuParts";
import { useSessionRef } from "./sessionRefModel";
import { useSessionHover } from "../started/useSessionHover";
import { resolveSessionRef, senderRef, sessionRefsResolve, whenIdle } from "./sessionRefs";
import { AgentMessageRow } from "./AgentMessageRow";
import { UnverifiedMark } from "./UnverifiedMark";
import { senderHarness, senderAbout, senderLabel } from "./incomingMessageCardModel";

/// A family sender's label, its relation before its name ("Parent · coordinator").
const RELATION_LABEL: Record<IncomingRelation, StringKey> = {
  parent: "message.from.parent",
  subsession: "message.from.subsession",
  ancestor: "message.from.ancestor",
  descendant: "message.from.descendant",
};

/// A harness logo's size in the sender's glyph slot (see SenderName).
const SENDER_LOGO_SIZE = 12;

/// The sender's mark alone (a received line's, an inbox group's): its avatar, a Chief's face, else
/// its harness's mark, else the neutral agent glyph in its own stable tone.
export function SenderMark({ message }: { message: IncomingMessage }) {
  const chief = useChiefFace(message.chief);
  // cmux's own notice (agentNotice.ts `system`) is no chat: a chat named `cmux` never stands in for it.
  const sender = useSenderChat(
    message.chief || message.program || message.notice?.system ? "" : (message.lookup ?? message.name),
    message.sessionId,
  );
  const avatar = useAgentAvatar(sender.sessionId);
  const harness = senderHarness(sender.harness, message.harness);
  const picture = message.chief ? chief?.src : avatar;
  // A sender that named its app ("Grok bot › Ada", u20190) wears that app's mark, else its monogram.
  if (!picture && !message.chief && message.app && !hasAgentMark(harness)) {
    return hasAgentMark(message.app) ? (
      <AgentIdentity harness={message.app} size={SENDER_LOGO_SIZE} fallbackNode={<Bot size={16} />} />
    ) : (
      <MonogramMark name={message.app} size={SENDER_LOGO_SIZE + 2} />
    );
  }
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
      // The sparkle fills more of its grid than the bot: at 14px its ink is the logos' (about 12px).
      glyphSize={14}
      fallbackNode={<Bot size={16} />}
    />
  );
}

/// A received message's mark in the one message row's icon column (AgentMessageRow.tsx): its
/// tooltip is what the sender runs on, as the mark's beside a name always said.
export function ReceivedMark({ message }: { message: IncomingMessage }) {
  const sender = useSenderChat(
    message.chief || message.program || message.notice?.system ? "" : message.name,
    message.sessionId,
  );
  const about = message.chief
    ? undefined
    : senderAbout(senderHarness(sender.harness, message.harness), sender.run, message);
  return (
    <span className="cv-received__mark" aria-hidden="true" title={about}>
      <SenderMark message={message} />
    </span>
  );
}

/// A notice's title on its line: what it is about, cut first when the line is short, then the outcome
/// that ends it (`(exit 2)`) and how many more notices went in with it, which the line always shows
/// whole (Leo, 2026-11-08: "why was there a yellow warning symbol?": the cut hid the exit).
function NoticeTitle({ notice }: { notice: AgentNotice }) {
  const { lead, end } = titleParts(notice.title);
  return (
    <>
      <span className="cv-notice__lead">{lead}</span>
      {end && <span className="cv-notice__end">{` ${end}`}</span>}
      {notice.more ? (
        <span className="cv-notice__more" data-find-skip="">
          +{notice.more}
        </span>
      ) : null}
    </>
  );
}

/// The name a received line gives its sender: the recorded session's own, from the session metadata
/// (senderIdentity.ts), as its preview and session card name it, whatever name the message fell back
/// to (a raw `acp:<id>` when its provenance carried no `fromName`). A Chief, an app's persona and a
/// person name themselves.
function useSenderSessionName(message: IncomingMessage, person: boolean): string {
  const session = !person && !message.chief && !message.app ? message.sessionId : undefined;
  const identity = useSenderIdentity({ name: session ? message.name : "", ...(session && { sessionId: session }) });
  return session ? identity.name : message.name;
}

/// The sender's mark and name at a received line's start (and a waiting group's sender head,
/// PendingMessagesCard.tsx): the name opens the sender's chat when there is one to open.
export function SenderName(props: {
  message: IncomingMessage;
  onOpen(sessionId: string): void;
  /// A tool's notice: its severity's mark in the icon column (not in the `tag` look, which keeps
  /// the sender's), and the machine it names after its name.
  toolNotice?: AgentNotice;
  look?: NoticeLook;
}) {
  return <SenderChip {...props} withMark />;
}

/// The sender's name (its chip, the machine it runs on, and an unverified sender's marker), and its
/// mark before it when `withMark`: the one message row (AgentMessageRow.tsx) draws the mark in its
/// icon column itself.
export function SenderChip({
  message,
  onOpen,
  toolNotice,
  look = "mark",
  withMark = false,
}: {
  message: IncomingMessage;
  onOpen(sessionId: string): void;
  toolNotice?: AgentNotice;
  look?: NoticeLook;
  withMark?: boolean;
}) {
  const t = useT();
  // A Chief's message names the Chief and draws its avatar (chiefFace.ts); its turn session is no
  // chat of the list, so no listed chat with its name stands in for it, and it is no chat to open.
  // A program acpmux saw send it (incomingMessage.ts `senderProgram`) is no chat either: a fleet
  // tool, never a lane that shares its name.
  const chief = useChiefFace(message.chief);
  const sender = useSenderChat(
    message.chief || message.program || message.notice?.system ? "" : (message.lookup ?? message.name),
    message.sessionId,
  );
  const recorded = useSenderSessionName(message, false);
  const name =
    (message.chief && chief?.name) ||
    (message.unverified && !message.name.trim() ? t("message.unverifiedSender") : senderLabel(recorded, sender.host));
  // Read only (a guest): the sender's chat is not this reader's to open.
  const readOnly = useTranscriptReadOnly();
  const listed = message.chief || readOnly ? undefined : sender.sessionId;
  const notice = laneNotice(message);
  const inboxNames =
    notice?.kind === "inbox"
      ? [...new Set((notice.threads ?? []).map(({ sender }) => sender).filter(Boolean))].join(", ")
      : "";
  // A sender the page's list cannot name (a lane on a machine this pane does not list, a name two
  // chats share) is asked of acpmux, as a `HOST/NAME` in a reply is (sessionRefs.ts): its chip is
  // the session link either way, never a pill a click does nothing on (Leo, 2026-11-05: "i can't
  // click to go to these for some reason"). A Chief, a tool's notice, an app's persona or a batch
  // of senders is no one chat to ask for.
  const asks =
    !listed &&
    !message.chief &&
    !readOnly &&
    !toolNotice &&
    !message.app &&
    !message.program &&
    !inboxNames &&
    (message.lookup ?? message.name).trim() !== "" &&
    sessionRefsResolve();
  // acpmux's record of who sent it, never the line's text, which may carry a note for the reader
  // ("(self-declared, unauthenticated)"): asked by that text, no chat ever matched (Leo, 2026-11-07).
  // A line with no record still has the note stripped (senderRef).
  const query = asks ? senderRef(message.lookup ?? message.name) || undefined : undefined;
  const resolved = useSessionRef(query, false);
  useEffect(
    () => (query && resolved === undefined ? whenIdle(() => void resolveSessionRef(query)) : undefined),
    [query, resolved],
  );
  const sessionId = listed ?? resolved?.sessionId;
  // The chat the name opens shows its hover card, as any reference to a chat does; the card opens it
  // as the name does, as a sender.
  const { trigger: hover, card } = useSessionHover(sessionId ?? "", onOpen);
  // The tab opens on the click, never after a round trip: by the chat's id once acpmux named it,
  // else by what the sender is asked for by, which the new tab resolves itself and, when no machine
  // here has that chat, says so in place (direct.ts `resolveMissing`). Leo, 2026-11-07: "I expect to
  // see, okay, my right pane is going to either gain a new tab or, like, split".
  const openAsked = () => {
    if (!query) return;
    onOpen(resolved?.sessionId ?? query);
  };
  const from = inboxNames || (message.relation ? t(RELATION_LABEL[message.relation], { name }) : name);
  const icon =
    toolNotice && look !== "tag" ? <NoticeMark severity={toolNotice.severity} /> : <SenderMark message={message} />;
  const host = toolNotice?.host ?? sender.host;
  // The harness, model and effort it runs on, under the name's tooltip and on the mark's.
  const about = message.chief
    ? undefined
    : senderAbout(senderHarness(sender.harness, message.harness), sender.run, message);
  // "Open chief-ui (studio-mac)": the chat the name opens, and the other machine it runs on.
  const openHost = sender.host ?? resolved?.host;
  const open = openHost ? t("subagents.openOnHost", { name, host: openHost }) : t("subagents.open", { name });
  const openTitle = about ? `${open}\n${about}` : open;
  return (
    // Its own part of the line: the name opens the sender's chat or nothing, never the message.
    <span className="cv-received__sender" data-own-click="">
      {withMark && (
        <span
          className="cv-received__mark"
          aria-hidden={toolNotice && look !== "tag" ? undefined : "true"}
          title={about}
        >
          {icon}
        </span>
      )}
      {sessionId ? (
        <AgentTag
          name={from}
          className="cv-received__from cv-received__from--open"
          title={openTitle}
          ariaLabel={open}
          attributes={openSessionAttributes(sessionId, true)}
          hover={hover}
          onClick={() => (listed ? onOpen(listed) : openAsked())}
        />
      ) : query ? (
        // Still being asked, or acpmux has no chat by that name: the click asks (or says so).
        <AgentTag
          name={from}
          className="cv-received__from cv-received__from--open"
          title={openTitle}
          ariaLabel={open}
          onClick={openAsked}
        />
      ) : (
        <AgentTag name={from} className="cv-received__from" title={about} />
      )}
      {/* A sender acpmux could not verify (Leo, 2026-11-05: "why is it sending it as if it were
          me?"): the one subtle marker, never words in or beside its name. The message row draws
          its own (AgentMessageRow.tsx `unverified`). */}
      {withMark && message.unverified && <UnverifiedMark program={message.program} claimed={message.name} />}
      {/* The other machine the sender's chat runs on, on the line itself, not only in the name's
          tooltip (Leo, 2026-10-27, on a lane's message: "Is this, like, from another machine? But
          even if they're from another machine, what's going on here?"). This Mac's chats name none. */}
      {host &&
        (readOnly ? <span className="cv-received__host">{host}</span> : <MachineMenu host={host} onOpen={onOpen} />)}
      {message.edited && <span className="cv-received__host">{t("message.edited")}</span>}
      {sessionId && card}
    </span>
  );
}

/// The machine a sender runs on, as a control (Leo, 2026-11-03, on the line's machine: "so what's
/// this depicting? session name, then machine? hm i wonder if there's anything interesting we can
/// click around wrt machines"): it opens a menu of the chats listed on that machine, each opening
/// beside this one as the sender's name does, and Copy machine name. Moving a chat between machines
/// comes next (cmuxterm-hq#763). The label keeps its muted look; only it highlights, never the line.
function MachineMenu({ host, onOpen }: { host: string; onOpen(sessionId: string): void }) {
  const t = useT();
  const chats = useMachineChats(host);
  const title = t("machineMenu.chats", { machine: host });
  return (
    <Menu>
      <MenuButton className="cv-received__host" data-menu="sender-machine" title={title} aria-haspopup="menu">
        <span className="cv-received__host-name">{host}</span>
      </MenuButton>
      <MenuPopup side="bottom" align="start" className="acpmux-quick-menu cv-machine-menu" label={title}>
        {chats.length > 0 && (
          <>
            <MenuGroup label={title}>
              {chats.map((chat) => (
                <MenuItem key={chat.sessionId} className="acpmux-quick-item" onSelect={() => onOpen(chat.sessionId)}>
                  {chat.name}
                </MenuItem>
              ))}
            </MenuGroup>
            <MenuSeparator />
          </>
        )}
        <MenuItem className="acpmux-quick-item" onSelect={() => void copyTextResult(host)}>
          {t("machineMenu.copyName")}
        </MenuItem>
      </MenuPopup>
    </Menu>
  );
}

/// A person's name at a received line's start (a guest's held prompt, QueuedMessageCard.tsx): their
/// face in the mark's column and their name, "<name> (guest)" for a link guest. A person is no chat.
function PersonName({ person }: { person: Participant }) {
  const t = useT();
  const from = isGuest(person) ? t("multiplayer.guestName", { name: person.name }) : person.name;
  return (
    <span className="cv-received__sender">
      <span className="cv-received__mark" aria-hidden="true">
        <Face person={person} />
      </span>
      <span className="cv-received__from">{from}</span>
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
  person,
  whole = false,
  files,
  images,
  videos,
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
  /// A person's message (a guest's held prompt, QueuedMessageCard.tsx): their face in the icon
  /// column and their name, "<name> (guest)" for a link guest, in place of an agent's.
  person?: Participant;
  /// Drawn whole and open, its text as sent (no cut, no Minimal Mode fold, no signature or
  /// reference rewriting): a guest's held message, which the owner approves as it is.
  whole?: boolean;
  /// The files the message sent (a recorded prompt's `inlineParts`), drawn as a sent prompt's.
  files?: readonly FileAttachmentInfo[];
  /// The images the message sent the agent (direct.ts `promptImages`).
  images?: readonly PromptImage[];
  /// The videos the message sent (sentVideos.ts), each its tile before the images, as a sent prompt's.
  videos?: readonly SentVideo[];
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
  // A person's message (drawn whole) is never a lane notice: what it looks like never hides any of
  // the text the owner approves.
  const notice = whole || person ? undefined : laneNotice(message);
  // A tool's notice (agentNotice.ts): its title is the line, its body and links the panel.
  const agentNotice = whole || person ? undefined : message.notice;
  const look = useNoticeLook();
  const session = useContext(PromptMarksSession);
  const key = `${session ?? ""}\u0000${id}`;
  // Whether the person opened it lasts while the page does (incomingOpened.ts), and the row
  // estimator reads it.
  const [opened, setOpen] = useState(() => messageOpened(session, id));
  const open = whole || opened;
  const lineLook = useMessageLineLook();
  const inPlace = useReceivedLook() === "card";
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
  const inText = Boolean(
    needle &&
    foldFind(
      agentNotice
        ? `${agentNotice.title}\n${message.text}`
        : (notice?.body ?? (whole ? message.text : unsigned(message.text, message.name))),
    ).includes(needle),
  );
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
  // A person is never a chat: their name never finds one (a guest names themselves).
  const sender = useSenderChat(
    person || message.chief || message.program || message.notice?.system ? "" : message.name,
    person ? undefined : message.sessionId,
  );
  // The session's own name, as SenderName shows it: a peer's `<machine>/<name>` reads as `<name>` in
  // the toggle's label and the reply editor's, the machine already shown beside it.
  const recorded = useSenderSessionName(message, Boolean(person));
  const name = (message.chief && chief?.name) || senderLabel(recorded, sender.host);
  const place = useSenderPlace(sender.sessionId);
  // The sender's words without a signature that only repeats its name (incomingMessage.ts reads
  // it on every path; a record from before that, or a queued one, may still have it).
  const text = agentNotice
    ? noticeMarkdown(message.text, agentNotice.links)
    : (notice?.body ?? (whole ? message.text : unsigned(message.text, message.name)));
  // The machine the sender's files are on, when it is another (a peer's relayed message names none).
  const host = message.remote ? (place?.host ?? "") : place?.host;
  const repository = githubRepository ?? mentionedRepository(text);
  const body = useMemo(() => (whole ? text : dedupeReferences(text, repository)), [whole, text, repository]);
  const scope = useMemo<MessageScope>(() => (host === undefined ? {} : { host }), [host]);
  const preview = useMemo(
    () => agentNotice?.title ?? notice?.preview ?? message.preview ?? messagePreview(body),
    [agentNotice, body, notice, message.preview],
  );
  // A sub-session family's sender says who it is to this chat.
  const from = person
    ? isGuest(person)
      ? t("multiplayer.guestName", { name: person.name })
      : person.name
    : message.relation
      ? t(RELATION_LABEL[message.relation], { name })
      : name;
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
  // The words: its card, from the card's corner, its images and files. In the `card` look
  // (`clamped`), cut between whole lines past eight with Show more, which opens the message as its
  // line does (ClampedText.tsx).
  const markdown = text ? (
    <Markdown githubRepository={repository} commits="quiet" thumbnails={host === undefined} messageAt={messageAt}>
      {body}
    </Markdown>
  ) : (
    t("message.noText")
  );
  const wordsOf = (clamped: boolean) => (
    <>
      {/* The sender's words, as written, from the card's corner. */}
      <CardCopy text={agentNotice ? `${agentNotice.title}\n\n${text}`.trim() : text} />
      {/* The chips read whose files these are (chips/messageScope.ts). */}
      <MessageScopeContext.Provider value={scope}>
        {clamped ? (
          <ClampedText className="cv-received__text selectable" expanded={open} onExpand={toggled} watch={body}>
            {markdown}
          </ClampedText>
        ) : (
          <div className="cv-received__text selectable">{markdown}</div>
        )}
      </MessageScopeContext.Provider>
      {(Boolean(images?.length) || Boolean(videos?.length)) && (
        <SentImages
          images={images ?? []}
          className="cv-message__images"
          leading={videos?.length ? <SentVideoTiles videos={videos} /> : null}
        />
      )}
      {files && files.length > 0 && (
        <div className="cv-user__files cv-message__files">
          {files.map((file, index) => (
            <FileAttachment key={index} file={file} />
          ))}
        </div>
      )}
    </>
  );
  // Under the words: the prompt as the agent got it, behind Details, and the reply.
  const below = (
    <>
      {raw !== undefined && (
        <div className="cv-received__details">
          <button
            ref={envelope.headerRef}
            type="button"
            className="cv-received__more"
            aria-expanded={details}
            aria-controls={details ? rawId : undefined}
            onClick={(event) => {
              if (envelope.toggle(event)) played.current = true;
            }}
          >
            {t("message.details")}
            <ChevronRight size={12} className={`cv-rotor${details ? " is-open" : ""}`} />
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
    </>
  );
  const hover = (
    <span className="cv-received__hover">
      {replies && !editing && (
        <button ref={replyButton} type="button" className="cv-received__reply" onClick={startReply}>
          {t("message.reply")}
        </button>
      )}
      {actions}
    </span>
  );
  // Another agent's message is the one message row (AgentMessageRow.tsx), as a send and a subagent's
  // report are: the sender's name after its family's mark in the icon column, the first
  // line, and the card that opens to the whole message (Leo, 2026-11-07: "They should look basically
  // the same as the other ones"). The `card` look (receivedLook.ts, a gallery version) keeps the card
  // under the line shut too, its words whole up to eight lines with Show more, which opens it as the
  // line does. A tool's notice, a lane's report and a person's held message keep their own line
  // below.
  if (!agentNotice && !notice && !person)
    return (
      <AgentMessageRow
        direction="received"
        keepsPreviewOpen
        className="cv-received"
        // Find counts the message's text (chatFind.ts rowText), never the line that sums it up: the
        // sender's chip and machine and the first line add no matches, as DisclosureRow's line added
        // none (cmux#37653 review).
        lineAttributes={{ "data-find-skip": "" }}
        icon={<ReceivedMark message={message} />}
        // The sender named once, first, as every received line reads (cmux#25002, #32711): the
        // family mark before it says which way the message went.
        sentence={"\u0000"}
        previewClassName="cv-received__preview"
        name={from}
        nameSlot={<SenderChip message={message} onOpen={onOpen} />}
        unverified={message.unverified === true}
        program={message.program}
        claimed={message.name}
        preview={preview || t("message.noText")}
        label={t("message.collapsedLabel", { from, preview: preview || t("message.noText") })}
        open={open}
        onToggle={() => toggled(!open)}
        animates={inPlace ? undefined : () => played.current}
        actions={hover}
        peek={inPlace ? wordsOf(true) : undefined}
        body={wordsOf(inPlace)}
        under={below}
      />
    );
  return (
    <DisclosureRow
      className={
        agentNotice
          ? `cv-received cv-notice is-${agentNotice.severity} look-${look}`
          : notice
            ? "cv-received cv-lane-notice"
            : "cv-received"
      }
      open={open}
      onOpenChange={toggled}
      animates={() => !notice && played.current}
      leading={
        person ? (
          <PersonName person={person} />
        ) : (
          <SenderName message={message} onOpen={onOpen} toolNotice={agentNotice} look={look} />
        )
      }
      lineClassName="cv-agent-activity-row"
      toggleLabel={t("message.collapsedLabel", { from, preview: preview || t("message.noText") })}
      label={
        // Find counts the panel's whole text, not the line's first-line copy of it. Single (the
        // default, messageLineLook.ts) a message's first line follows the sender on its line.
        // A notice's title is its text (the row's, which Find searches) and stays on the line: Find
        // highlights it here, inside the line Find otherwise skips (chatFind.ts `findSkipped`).
        lineLook === "single" || agentNotice ? (
          <span
            className={`cv-received__preview${agentNotice ? " cv-notice__title" : ""}`}
            data-find-skip={agentNotice ? undefined : ""}
            data-find-keep={agentNotice ? "" : undefined}
            // A notice's title is one Find run: a match may span its command and its exit.
            data-find-join={agentNotice ? "" : undefined}
          >
            {agentNotice && look === "tag" && agentNotice.severity !== "info" && (
              <span className="cv-notice__tag" data-severity={agentNotice.severity} data-find-skip="">
                {t(SEVERITY_LABEL[agentNotice.severity])}
              </span>
            )}
            {agentNotice ? <NoticeTitle notice={agentNotice} /> : preview || t("message.noText")}
          </span>
        ) : null
      }
      below={lineLook === "stacked" && !open && !agentNotice ? preview || t("message.noText") : undefined}
      // It opens at once, its height alone moving, as the message's card always did; closing fades.
      fadeIn={false}
      // One slot at the line's end, over the preview's tail, shown on hover or focus: it never moves
      // the chevron, which ends every message's line at the same place (conversation.css).
      actions={hover}
    >
      {wordsOf(false)}
      {below}
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
