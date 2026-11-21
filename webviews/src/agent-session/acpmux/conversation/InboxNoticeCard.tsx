// acpmux's inbox notice (inboxNotice.ts) in the transcript: each of its threads is another agent's
// received line, drawn as IncomingMessageCard.tsx draws a message (Leo, 2026-10-31, on the notice
// shown as the person's bubbles: "isn't this rendered pretty terribly? why do we have this like
// this? why is there so much additional text?"). The line: the newest message's sender (its mark,
// and its name, which opens its chat), the thread's label (`#N` or the topic), and "+N more" when
// the thread brought more. Under it, shut, the newest message's whole text, cut between whole
// lines past eight with Show more (ClampedText.tsx), so what another agent said reads in place, never
// behind `acpmux session inbox --thread` in a shell (Leo, 2026-11-09: "if cmux-next could be the
// bridge between claude desktop and codex desktop, that'd be super cool. we should keep going
// further into the whole messaging system type situation"). "+N more", the line or its chevron open
// the whole thread in the same card, oldest first, each message under its sender and age, the newest
// `THREAD_PAGE` of them until the person asks for earlier ones. The messages are the notice's own
// copy when it held them, else read from acpmux (`_acpmux/inbox_thread`, through
// `chat.inbox.thread`) as the line first draws (inboxThreadRead.ts keeps the read for the page),
// without marking them read (the person reading is not the agent). Nothing of the notice's text for
// the agent shows. The `drill` look (inboxThreadLook.ts) opens the thread as rows to drill into.
// Two or more threads (a notice of several, or notices next to each other, mergeInboxNotices) draw
// as one group: one line, "N messages from M sessions" and the senders muted, a sibling of the tool rows (the tool row's box, its
// glyph the sender's mark in their icon column), that opens to the threads' lines; the versions
// beside it are inboxNoticeLook.ts's. Whether a line or the group is open lasts while the page does
// (incomingOpened.ts), and the row estimator (model.ts) reads it. Everything opens on the click,
// with no fade in.
import { useContext, useEffect, useId, useLayoutEffect, useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { useMinuteClock } from "../clock";
import { shortAge } from "../sessionList";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { mentionedRepository } from "../../../githubReferences";
import { CardCopy } from "./CardCopy";
import { ClampedText } from "./ClampedText";
import { ExpandRow } from "./ExpandRow";
import { HEADER_TOGGLES_ATTRIBUTE } from "./headerToggle";
import { ChevronLeft } from "./icons";
import { FindReveal, foldFind } from "./chatFind";
import { ReceivedMark, SenderChip } from "./IncomingMessageCard";
import { AgentMessageRow } from "./AgentMessageRow";
import { messagePreview } from "./agentMessageRowModel";
import { MessageGroupHead } from "./MessageGroupHead";
import { groupSender } from "./messageGroupHeadModel";
import { messageOpened, setDigestOpened, setMessageOpened } from "./incomingOpened";
import type { IncomingMessage } from "./incomingMessage";
import {
  inboxCounts,
  inboxThreadKey,
  senderKey,
  type InboxMessage,
  type InboxNotice,
  type InboxThread,
} from "./inboxNotice";
import { foldsThreads, useInboxNoticeLook } from "./inboxNoticeLook";
import { fitsLine, newestWholeKey, readForIds, setThreadRead, THREAD_PAGE, threadRead } from "./inboxThreadRead";
import { useInboxThreadLook } from "./inboxThreadLook";
import { Markdown } from "./Markdown";
import { inboxHover } from "./MessageGroupHover";
import { withoutRelayEnvelope } from "./relayEnvelope";
import { bareSender } from "./senderIdentity";
import { SentFromLine } from "./SentFromLine";
import { shownOfCut } from "./markdownCut";
import "./InboxNoticeCard.css";
import { signed } from "../../../ui/Typography";

/// Reads a thread's messages, oldest first (App.tsx `readInboxThread`, `chat.inbox.thread`).
export type ReadInboxThread = (threadId: string) => Promise<InboxMessage[]>;

/// The sender a thread's line names: the newest message's.
function newestSender(thread: InboxThread): string {
  return thread.messages?.at(-1)?.from || thread.from.at(-1) || "";
}

/// The key the newest sender's chat is asked for by (`senderKey`), when acpmux recorded who sent it.
function newestLookup(thread: InboxThread): string | undefined {
  const newest = thread.messages?.at(-1);
  const sender = newest ? newest.sender : thread.sender;
  return sender && senderKey(newestSender(thread), sender);
}

/// A message's sender and its age ("lane-a · 5m"), over the message in an opened thread. Its own
/// component, so only an opened thread follows the minute clock.
function MessageHead({ from, at }: { from: string; at?: number }) {
  const t = useT();
  const now = useMinuteClock();
  return (
    <div className="cv-inbox__from" data-find-skip="">
      {from}
      {at !== undefined && (
        <>
          {" · "}
          <time dateTime={new Date(at).toISOString()}>{shortAge(at, now, t)}</time>
        </>
      )}
    </div>
  );
}

/// One message of a thread, whole: its head when the thread has several, its Markdown, and where it
/// says it came from.
function ThreadMessage({
  message,
  head,
  thread,
  repository,
  messageAt,
}: {
  message: InboxMessage;
  head: boolean;
  thread: InboxThread;
  repository?: string;
  messageAt?: number;
}) {
  return (
    <section className="cv-inbox__message">
      {head && message.from && <MessageHead from={message.from} at={message.at} />}
      <Markdown githubRepository={repository} commits="quiet" messageAt={message.at ?? messageAt}>
        {message.text}
      </Markdown>
      {message.promptId && thread.sentFrom?.[message.promptId] && (
        <SentFromLine from={thread.sentFrom[message.promptId]!} />
      )}
    </section>
  );
}

/// The `drill` look's opened thread (inboxThreadLook.ts), as the Background tasks panel drills in: a
/// back control and the thread's name over a row per message (its sender, age and first line); a
/// row opens its message whole under a back control to the rows.
function ThreadDrill({
  title,
  messages,
  thread,
  repository,
  messageAt,
  onClose,
}: {
  title: string;
  messages: InboxMessage[];
  thread: InboxThread;
  repository?: string;
  messageAt?: number;
  onClose(): void;
}) {
  const t = useT();
  const [picked, setPicked] = useState<number>();
  const message = picked === undefined ? undefined : messages[picked];
  const back = message ? () => setPicked(undefined) : onClose;
  return (
    <div className="cv-inbox__drill">
      <div className="cv-inbox__drill-head">
        {/* `aria-expanded` here and on the rows: the transcript holds the line where it is drawn while
            the card changes under it (foldAnchor.ts `FOLD_TOGGLE`). */}
        <button type="button" className="cv-inbox__back" aria-label={t("inbox.back")} aria-expanded onClick={back}>
          <ChevronLeft size={14} />
        </button>
        <span className="cv-inbox__drill-title">{message ? message.from : title}</span>
      </div>
      {message ? (
        <ThreadMessage message={message} head={false} thread={thread} repository={repository} messageAt={messageAt} />
      ) : (
        <ul className="cv-inbox__rows">
          {messages.map((m, index) => (
            <li key={m.promptId ?? index}>
              <button type="button" className="cv-inbox__row" aria-expanded={false} onClick={() => setPicked(index)}>
                <MessageHead from={m.from} at={m.at} />
                <span className="cv-inbox__row-preview">{messagePreview(m.text)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/// One thread's received line: shut, the newest message's text under it, cut to eight lines with
/// Show more; opened, the whole thread in its place.
function InboxThreadLine({
  rowId,
  thread,
  messageAt,
  onOpen,
  readThread,
  githubRepository,
  actions,
}: {
  rowId: string;
  thread: InboxThread;
  messageAt?: number;
  onOpen(sessionId: string): void;
  readThread?: ReadInboxThread;
  githubRepository?: string;
  actions?: ReactNode;
}) {
  const t = useT();
  const look = useInboxThreadLook();
  const session = useContext(PromptMarksSession);
  const id = inboxThreadKey(rowId, thread.threadId);
  const [open, setOpen] = useState(() => messageOpened(session, id));
  const show = (next: boolean) => {
    setMessageOpened(session, id, next);
    setOpen(next);
  };
  const [whole, setWhole] = useState(() => messageOpened(session, newestWholeKey(id)));
  const showWhole = (next: boolean) => {
    setMessageOpened(session, newestWholeKey(id), next);
    setWhole(next);
  };
  const [shown, setShown] = useState(THREAD_PAGE);
  // The notice's own copy, else what acpmux has (its new messages, by id), read once for the page
  // (inboxThreadRead.ts). A read belongs to the messages it was for: a later notice for the thread
  // (new ids) reads again.
  const own = thread.messages?.length ? thread.messages : undefined;
  const readFor = readForIds(thread.promptIds);
  const [read, setRead] = useState<{ for: string; messages?: InboxMessage[] }>();
  const cached = threadRead(session, id, readFor);
  const fetched =
    read?.for === readFor ? read : cached !== undefined ? { for: readFor, messages: cached ?? undefined } : undefined;
  const messages = own ?? fetched?.messages;
  // A line the notice gave only a preview (its messages past acpmux's 4 KB, an older acpmux) reads
  // its messages as it draws, so its newest message shows whole without the person asking (Leo,
  // 2026-11-09, reading a thread through `acpmux session inbox` in a shell). The transcript draws
  // only the rows in view, so only those read. One whose notice held the newest message whole
  // (`newest`, hub/inbox.rs) draws it at once and reads the rest only when it opens.
  const wanted = !own && (open || thread.newest === undefined);
  const hasRead = fetched !== undefined;
  useEffect(() => {
    if (!wanted || hasRead || !readThread) return;
    let live = true;
    readThread(thread.threadId).then(
      (all) => {
        if (!live) return;
        const ids = new Set(thread.promptIds);
        const mine = all.filter((m) => m.promptId !== undefined && ids.has(m.promptId));
        // Whatever the reader hands back (the native `chat.inbox.thread` passes acpmux's records
        // through) draws without the broker's label or an older acpmux's suffix on the name.
        const drawn = (mine.length ? mine : all.slice(-thread.count)).map((m) => {
          const from = bareSender(m.from);
          return {
            ...m,
            from: from.name,
            text: withoutRelayEnvelope(m.text),
            ...(from.declared && m.unverified === undefined && { unverified: true as const }),
          };
        });
        // Nothing read keeps the preview, and is not asked for again until new messages come.
        setThreadRead(session, id, readFor, drawn.length > 0 ? drawn : null);
        setRead({ for: readFor, ...(drawn.length > 0 && { messages: drawn }) });
      },
      // The preview stays: acpmux no longer holds the thread, or the chat is gone. The next draw
      // asks again.
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [wanted, hasRead, readFor, readThread, thread, session, id]);
  const name = newestSender(thread);
  const lookup = newestLookup(thread);
  const newest = messages?.at(-1);
  // Its session: the thread's, else its sender record's (an acpmux that names the sender's session
  // only there), so the name resolves and opens its chat.
  const senderSession = thread.fromSession ?? newest?.sender?.session ?? thread.sender?.session;
  const sender = useMemo<IncomingMessage>(
    () => ({
      name,
      ...(lookup && { lookup }),
      text: "",
      raw: "",
      ...(senderSession && { sessionId: senderSession }),
      ...((thread.fromHarness ?? newest?.harness) && { harness: thread.fromHarness ?? newest?.harness }),
      ...((thread.unverified || newest?.unverified) && { unverified: true as const }),
    }),
    [name, lookup, senderSession, thread.fromHarness, thread.unverified, newest?.harness, newest?.unverified],
  );
  const all = messages?.map((m) => m.text).join("\n\n") ?? thread.newest ?? thread.preview;
  const repository = githubRepository ?? mentionedRepository(all);
  // Find opens the line that holds the match (the row's text is every thread's messages).
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  const holds = Boolean(needle && foldFind(all).includes(needle));
  useLayoutEffect(() => {
    if (!holds || open) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [holds, reveal]);
  // Several messages each say who sent them and when; one alone is under its sender's line already.
  const heads = (messages?.length ?? 0) > 1;
  // The newest message: read whole, else the notice's preview until it is.
  // acpmux's preview is a cut first line (hub/inbox.rs): never draw a cut span (#39100).
  const wholePreview = thread.preview?.endsWith("…") ? shownOfCut(thread.preview) : thread.preview;
  const newestText = newest?.text ?? thread.newest ?? wholePreview;
  const label = thread.label && thread.label !== name ? thread.label : undefined;
  const earlier = messages ? Math.max(0, messages.length - shown) : 0;
  // Where the newest message says it came from (`sender_claim`), under it as under an opened one.
  const newestPrompt = newest?.promptId ?? (thread.promptIds.length === 1 ? thread.promptIds[0] : undefined);
  const newestFrom = newestPrompt ? thread.sentFrom?.[newestPrompt] : undefined;
  // A short one-line message, known whole, reads on the line as another agent's received line
  // does, and the line keeps the one-line rows' pitch; anything longer reads in the card under it.
  const known = newest?.text ?? thread.newest;
  const onLine = fitsLine(known);
  const preview = onLine ? known.trim() : thread.preview || (newest ? messagePreview(newest.text) : "");
  // The one message row (AgentMessageRow.tsx), as a received message draws: the sender's name after
  // its family's mark, the thread's label and "+N more" after the name. Shut, the card under it holds
  // the newest message (Leo, 2026-11-07: "why can't I see the full excerpt of its message?"); "+N
  // more", the line or its chevron open the whole thread in the same card.
  return (
    <AgentMessageRow
      direction="received"
      className="cv-received cv-inbox__thread"
      // Find counts the thread's messages, never the line that sums them up (IncomingMessageCard.tsx).
      lineAttributes={{ "data-find-skip": "" }}
      icon={<ReceivedMark message={sender} />}
      // The sender named once, first, as every received line reads (cmux#25002, #32711): the
      // family mark before it says which way the message went.
      sentence={"\u0000"}
      previewClassName="cv-received__preview"
      name={name}
      nameSlot={<SenderChip message={sender} onOpen={onOpen} />}
      unverified={sender.unverified === true}
      claimed={name}
      detail={
        <>
          {/* A thread keyed by its sender (`declared:NAME`) is labeled with that name: said once. */}
          {label && <span className="cv-inbox__label">{label}</span>}
          {thread.count > 1 && (
            // The line's own toggle takes its click (headerToggle.ts), anchored as the line's is.
            <button
              type="button"
              className="cv-inbox__more"
              aria-expanded={open}
              aria-label={t("inbox.showThread")}
              {...{ [HEADER_TOGGLES_ATTRIBUTE]: "" }}
            >
              {signed(t("tools.more", { n: thread.count - 1 }))}
            </button>
          )}
        </>
      }
      preview={preview}
      label={t("message.collapsedLabel", { from: name, preview: preview || t("message.noText") })}
      open={open}
      onToggle={() => show(!open)}
      actions={actions}
      keepsPreviewOpen={onLine}
      peek={
        onLine ? undefined : (
          <>
            <CardCopy text={newestText} />
            <ClampedText
              className="cv-received__text cv-inbox__newest selectable"
              expanded={whole}
              onExpand={showWhole}
              watch={newestText}
            >
              {newestText ? (
                <Markdown githubRepository={repository} commits="quiet" messageAt={newest?.at ?? messageAt}>
                  {newestText}
                </Markdown>
              ) : null}
            </ClampedText>
            {newestFrom && <SentFromLine from={newestFrom} />}
          </>
        )
      }
      body={
        <>
          <CardCopy text={all} />
          {messages && look === "drill" ? (
            <ThreadDrill
              title={label ?? name}
              messages={messages}
              thread={thread}
              repository={repository}
              messageAt={messageAt}
              onClose={() => show(false)}
            />
          ) : (
            <div className="cv-received__text selectable">
              {earlier > 0 && (
                <ExpandRow
                  className="cv-inbox__earlier"
                  open={false}
                  label={t("inbox.earlier")}
                  onToggle={() => setShown(shown + THREAD_PAGE)}
                />
              )}
              {messages ? (
                messages
                  .slice(earlier)
                  .map((message, index) => (
                    <ThreadMessage
                      key={message.promptId ?? earlier + index}
                      message={message}
                      head={heads}
                      thread={thread}
                      repository={repository}
                      messageAt={messageAt}
                    />
                  ))
              ) : newestText ? (
                <>
                  <Markdown githubRepository={repository} commits="quiet" messageAt={messageAt}>
                    {newestText}
                  </Markdown>
                  {thread.promptIds.length === 1 && thread.sentFrom?.[thread.promptIds[0]!] && (
                    <SentFromLine from={thread.sentFrom[thread.promptIds[0]!]!} />
                  )}
                </>
              ) : null}
            </div>
          )}
        </>
      }
    />
  );
}

export function InboxNoticeCard({
  rowId,
  notice,
  messageAt,
  onOpen,
  readThread,
  githubRepository,
  actions,
}: {
  /// The row's id, which keeps its lines and its group open across remounts.
  rowId: string;
  notice: InboxNotice;
  messageAt?: number;
  /// Opens a sender's chat by its acpmux id.
  onOpen(sessionId: string): void;
  readThread?: ReadInboxThread;
  githubRepository?: string;
  actions?: ReactNode;
}) {
  const t = useT();
  const look = useInboxNoticeLook();
  const session = useContext(PromptMarksSession);
  const [open, setOpen] = useState(() => messageOpened(session, rowId));
  const show = (next: boolean) => {
    setMessageOpened(session, rowId, next);
    setOpen(next);
  };
  const bodyId = useId();
  const grouped = notice.threads.length > 1 && foldsThreads(look);
  // Find opens the group for a match in one of its threads; the thread's line opens itself.
  const reveal = useContext(FindReveal);
  const holdsMatch = grouped && Boolean(reveal && reveal.rowId === rowId);
  useLayoutEffect(() => {
    if (!holdsMatch || open) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [holdsMatch, reveal]);
  const lines = notice.threads.map((thread) => (
    <InboxThreadLine
      key={thread.threadId}
      rowId={rowId}
      thread={thread}
      messageAt={messageAt}
      onOpen={onOpen}
      readThread={readThread}
      githubRepository={githubRepository}
      actions={actions}
    />
  ));
  if (!grouped) {
    const card = look === "card" && notice.threads.length > 1;
    return <div className={card ? "cv-inbox cv-inbox--card" : "cv-inbox"}>{lines}</div>;
  }
  const { messages, senders } = inboxCounts(notice);
  const count =
    senders.length === 1
      ? t("message.waitingFromOne", { n: messages })
      : t("message.waitingFrom", { n: messages, sessions: senders.length });
  // One sender: its mark, from its newest thread (its session and bound harness); several, even
  // under one name (two sessions, or two harnesses: cmux#30821), the messages glyph.
  const lead =
    senders.length === 1
      ? groupSender(
          notice.threads.map((thread) => ({
            name: newestSender(thread) || senders[0]!,
            ...(newestLookup(thread) && { lookup: newestLookup(thread) }),
            text: "",
            raw: "",
            ...((thread.fromSession ?? thread.sender?.session) && {
              sessionId: thread.fromSession ?? thread.sender?.session,
            }),
            ...(thread.fromHarness && { harness: thread.fromHarness }),
          })),
        )
      : undefined;
  return (
    <div className="cv-inbox cv-inbox--group" data-look={look} data-open={open || undefined}>
      {/* Find counts the messages' words, not the head's names. */}
      <MessageGroupHead
        sender={lead && { ...lead, name: senders[0]! }}
        count={count}
        senders={senders.join(", ")}
        open={open}
        bodyId={bodyId}
        onToggle={() => {
          // The head opens the group with every thread's messages open (incomingOpened.ts).
          setDigestOpened(
            session,
            rowId,
            notice.threads.map((thread) => inboxThreadKey(rowId, thread.threadId)),
            !open,
          );
          setOpen(!open);
        }}
        className="cv-inbox__head"
        messages={inboxHover(notice.threads)}
      />
      {open && (
        <div id={bodyId} className="cv-inbox__body">
          {lines}
        </div>
      )}
    </div>
  );
}
