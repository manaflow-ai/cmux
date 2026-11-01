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
import { Icon } from "../icons/Icon";
import { ChevronRight } from "./icons";
import { rowIconSize } from "../icons/iconSize";
import { DisclosureRow } from "../subagents/DisclosureRow";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { mentionedRepository } from "../../../githubReferences";
import { CardCopy } from "./CardCopy";
import { FindReveal, foldFind } from "./chatFind";
import { SenderMark, SenderName } from "./IncomingMessageCard";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import type { IncomingMessage } from "./incomingMessage";
import { inboxCounts, inboxThreadKey, type InboxMessage, type InboxNotice, type InboxThread } from "./inboxNotice";
import { foldsThreads, useInboxNoticeLook } from "./inboxNoticeLook";
import { Markdown } from "./Markdown";
import "./InboxNoticeCard.css";

const ROW_ICON = rowIconSize(12);

/// Reads a thread's messages, oldest first (App.tsx `readInboxThread`, `chat.inbox.thread`).
export type ReadInboxThread = (threadId: string) => Promise<InboxMessage[]>;

/// The sender a thread's line names: the newest message's.
function newestSender(thread: InboxThread): string {
  return thread.messages?.at(-1)?.from || thread.from.at(-1) || "";
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
  useEffect(() => {
    if (!open || own || fetched || !readThread) return;
    let live = true;
    readThread(thread.threadId).then(
      (all) => {
        if (!live) return;
        const ids = new Set(thread.promptIds);
        const mine = all.filter((m) => m.promptId !== undefined && ids.has(m.promptId));
        const shown = mine.length ? mine : all.slice(-thread.count);
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
  }, [open, own, fetched, readFor, readThread, thread]);
  const name = newestSender(thread);
  const sender = useMemo<IncomingMessage>(
    () => ({
      name,
      text: "",
      raw: "",
      ...(thread.fromSession && { sessionId: thread.fromSession }),
      ...(thread.fromHarness && { harness: thread.fromHarness }),
    }),
    [name, thread.fromSession, thread.fromHarness],
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
  return (
    <DisclosureRow
      className="cv-received cv-inbox__thread"
      open={open}
      onOpenChange={show}
      fadeIn={false}
      leading={<SenderName message={sender} onOpen={onOpen} />}
      toggleLabel={t("message.collapsedLabel", { from: name, preview: thread.preview || t("message.noText") })}
      actions={actions}
      label={
        <>
          {thread.label && <span className="cv-inbox__label">{thread.label}</span>}
          <span className="cv-received__preview" data-find-skip="">
            {thread.preview || t("message.noText")}
          </span>
          {thread.count > 1 && <span className="cv-inbox__more">{t("tools.more", { n: thread.count - 1 })}</span>}
        </>
      }
    >
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
            </section>
          ))
        ) : (
          <Markdown githubRepository={repository} commits="quiet" messageAt={messageAt}>
            {thread.preview || t("message.noText")}
          </Markdown>
        )}
      </div>
    </DisclosureRow>
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
  // One sender: its mark, from its newest thread (its session and bound harness); several: the
  // messages glyph.
  const lead = [...notice.threads].reverse().find((thread) => newestSender(thread) === senders[0]);
  return (
    <div className="cv-inbox cv-inbox--group" data-look={look} data-open={open || undefined}>
      {/* A sibling of the tool rows (Leo, 2026-11-01, on this line: "let's just make this look
          better"): the tool row's own box (conversation.css .cv-tool), its glyph in their icon column,
          the count as the summary and the senders muted after it, the chevron after them, shown on
          hover. Find counts the messages' words, not the head's names. */}
      <button
        type="button"
        className="cv-tool cv-inbox__head"
        data-find-skip=""
        aria-expanded={open}
        aria-controls={open ? bodyId : undefined}
        title={senders.join(", ")}
        onClick={() => show(!open)}
      >
        <span className="cv-tool__icon" aria-hidden="true">
          {senders.length === 1 && lead ? (
            <SenderMark
              message={{
                name: senders[0]!,
                text: "",
                raw: "",
                ...(lead.fromSession && { sessionId: lead.fromSession }),
                ...(lead.fromHarness && { harness: lead.fromHarness }),
              }}
            />
          ) : (
            <Icon name="agent.chat" size={ROW_ICON} row />
          )}
        </span>
        <span className="cv-tool__text">
          <span className="cv-inbox__count">{count}</span>
          <span className="cv-inbox__senders">{senders.join(", ")}</span>
        </span>
        <span className="cv-tool__chevron" aria-hidden="true">
          <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
        </span>
      </button>
      {open && (
        <div id={bodyId} className="cv-inbox__body">
          {lines}
        </div>
      )}
    </div>
  );
}
