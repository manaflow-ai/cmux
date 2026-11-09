// acpmux's inbox notice (inboxNotice.ts) in the transcript: each of its threads is another agent's
// received line, drawn as IncomingMessageCard.tsx draws a message (Leo, 2026-10-31, on the notice
// shown as the person's bubbles: "isn't this rendered pretty terribly? why do we have this like
// this? why is there so much additional text?"). The line: the newest message's sender (its mark,
// and its name, which opens its chat), the thread's label (`#N` or the topic), the newest message's
// first line, and "+N more" when the thread brought more. A click opens the thread's new messages
// whole, oldest first, under it: the notice's own copy when it held them, else read from acpmux
// (`_acpmux/inbox_thread`, through `chat.inbox.thread`) when the line first opens, without marking
// them read (the person reading is not the agent). Nothing of the notice's text for the agent shows.
// Two or more threads (a notice of several, or notices next to each other, mergeInboxNotices) draw
// as one group: one line, "N messages from M sessions" and the senders muted, a sibling of the tool rows (the tool row's box, its
// glyph the sender's mark in their icon column), that opens to the threads' lines; the versions
// beside it are inboxNoticeLook.ts's. Whether a line or the group is open lasts while the page does
// (incomingOpened.ts), and the row estimator (model.ts) reads it. Everything opens on the click,
// with no fade in.
import { useContext, useEffect, useId, useLayoutEffect, useMemo, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { mentionedRepository } from "../../../githubReferences";
import { CardCopy } from "./CardCopy";
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
import { Markdown } from "./Markdown";
import { inboxHover } from "./MessageGroupHover";
import { withoutRelayEnvelope } from "./relayEnvelope";
import { bareSender } from "./senderIdentity";
import { SentFromLine } from "./SentFromLine";
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

/// One thread's received line, and its messages under it once opened.
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
  const session = useContext(PromptMarksSession);
  const id = inboxThreadKey(rowId, thread.threadId);
  const [open, setOpen] = useState(() => messageOpened(session, id));
  const show = (next: boolean) => {
    setMessageOpened(session, id, next);
    setOpen(next);
  };
  // The notice's own copy, else what acpmux has once the line opens (its new messages, by id). A
  // read belongs to the messages it was for: a later notice for the thread (new ids) reads again.
  const own = thread.messages?.length ? thread.messages : undefined;
  const readFor = thread.promptIds.join("\u0000");
  const [read, setRead] = useState<{ for: string; messages?: InboxMessage[] }>();
  const fetched = read?.for === readFor ? read : undefined;
  const messages = own ?? fetched?.messages;
  // A line whose preview holds none of the message (an older acpmux cut a relayed message's preview
  // inside the broker's label: inboxNotice.ts) reads its messages as it draws, so its line says what
  // was sent; any other reads them when the person opens it.
  const wanted = open || !thread.preview;
  useEffect(() => {
    if (!wanted || own || fetched || !readThread) return;
    let live = true;
    readThread(thread.threadId).then(
      (all) => {
        if (!live) return;
        const ids = new Set(thread.promptIds);
        const mine = all.filter((m) => m.promptId !== undefined && ids.has(m.promptId));
        // Whatever the reader hands back (the native `chat.inbox.thread` passes acpmux's records
        // through) draws without the broker's label or an older acpmux's suffix on the name.
        const shown = (mine.length ? mine : all.slice(-thread.count)).map((m) => {
          const from = bareSender(m.from);
          return {
            ...m,
            from: from.name,
            text: withoutRelayEnvelope(m.text),
            ...(from.declared && m.unverified === undefined && { unverified: true as const }),
          };
        });
        // Nothing read keeps the preview, and is not asked for again until new messages come.
        setRead({ for: readFor, ...(shown.length > 0 && { messages: shown }) });
      },
      // The preview stays: acpmux no longer holds the thread, or the chat is gone. The next open
      // asks again.
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [wanted, own, fetched, readFor, readThread, thread]);
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
  const whole = messages?.map((m) => m.text).join("\n\n") ?? thread.preview;
  const repository = githubRepository ?? mentionedRepository(whole);
  // Find opens the line that holds the match (the row's text is every thread's messages).
  const reveal = useContext(FindReveal);
  const needle = reveal && reveal.rowId === rowId ? reveal.needle : "";
  const holds = Boolean(needle && foldFind(whole).includes(needle));
  useLayoutEffect(() => {
    if (!holds || open) return;
    show(true);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [holds, reveal]);
  // Several messages each say who sent them; one alone is under its sender's line already.
  const heads = (messages?.length ?? 0) > 1;
  // The newest message's first line: the notice's preview, else the message once read.
  const preview = thread.preview || (newest ? messagePreview(newest.text) : "");
  // The one message row (AgentMessageRow.tsx), as a received message draws: the sender's name after
  // its family's mark, the thread's label and "+N more" after the name, then the first
  // line; opened, the thread's messages whole in the card (Leo, 2026-11-07: "why can't I see the
  // full excerpt of its message?").
  return (
    <AgentMessageRow
      direction="received"
      keepsPreviewOpen
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
      detail={
        <>
          {/* A thread keyed by its sender (`declared:NAME`) is labeled with that name: said once. */}
          {thread.label && thread.label !== name && <span className="cv-inbox__label">{thread.label}</span>}
          {thread.count > 1 && (
            <span className="cv-inbox__more">{signed(t("tools.more", { n: thread.count - 1 }))}</span>
          )}
        </>
      }
      preview={preview}
      label={t("message.collapsedLabel", { from: name, preview: preview || t("message.noText") })}
      open={open}
      onToggle={() => show(!open)}
      actions={actions}
      body={
        <>
          <CardCopy text={whole} />
          <div className="cv-received__text selectable">
            {messages ? (
              messages.map((message, index) => (
                <section key={message.promptId ?? index} className="cv-inbox__message">
                  {heads && message.from && (
                    <div className="cv-inbox__from" data-find-skip="">
                      {message.from}
                    </div>
                  )}
                  <Markdown githubRepository={repository} commits="quiet" messageAt={message.at ?? messageAt}>
                    {message.text}
                  </Markdown>
                  {message.promptId && thread.sentFrom?.[message.promptId] && (
                    <SentFromLine from={thread.sentFrom[message.promptId]!} />
                  )}
                </section>
              ))
            ) : thread.preview ? (
              <>
                <Markdown githubRepository={repository} commits="quiet" messageAt={messageAt}>
                  {thread.preview}
                </Markdown>
                {thread.promptIds.length === 1 && thread.sentFrom?.[thread.promptIds[0]!] && (
                  <SentFromLine from={thread.sentFrom[thread.promptIds[0]!]!} />
                )}
              </>
            ) : null}
          </div>
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
