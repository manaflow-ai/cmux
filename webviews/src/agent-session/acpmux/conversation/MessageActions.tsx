// The buttons of a message's action row, shared by a prompt's (UserBubble.tsx, PromptActions for
// the Chief's), another agent's message's (ReceivedActions) and an answer's (TurnRows.tsx TurnFooter), as Claude Code desktop
// draws them: the message's age ("8 minutes ago"; "Oct 20, 2026, 10:16 PM" above it on hover; MessageTime, the same for a reply), a
// prompt's read receipt, Copy, Retry, Fork from here (its title and what it does), Pin, Read
// aloud and More (the message's right-click menu), each glyph ROW_ICON px in a 24 px button. The rows show on hover or keyboard focus only,
// with Claude's fade (conversation.css).
import { useContext, useRef, useState, type ReactNode } from "react";
import { PresentationContext } from "./presentationContextModel";
import { useLabelClock } from "../clock";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { BookmarkIcon } from "../threadMinimap/BookmarkIcon";
import { useRowMark } from "../threadMinimap/promptMarks";
import { AlertCircle, Check, DoubleCheck, Pin, Retry, Speaker, Spinner, StopReading, TurnFork } from "./icons";
import { canReadAloud, readAloud, useReadingAloud } from "./readAloud";
import { exactTime, messageAge, nextMessageAge } from "./relativeTime";
import { CopyButton } from "./CopyButton";
import { copyMarkdownResult } from "../richClipboard";
import { hasMessageMenuHost, openMessageMenu, openForkMenu } from "./messageMenu";
import { RetryModelMenu } from "./RetryModelMenu";
import { RowReplyButton } from "./SelectionReply";
import { RetryTargetContext, TurnActionsContext, type QueuedActions } from "./turnActions";
import { retryPlacement } from "./turns";
import { useTranscriptReadOnly } from "./readOnly";
import { ROW_ICON } from "./messageActionsModel";
import { resendsAttachments } from "../inlinePrompt";
/// The message's age, relative and live ("just now", "8 minutes ago", "yesterday", "Oct 18" past a
/// week: messageAge), the exact date and time above it on hover, as Claude's. A prompt's, another
/// agent's and a reply's rows all draw this one label (Leo, 2026-11-08: "the timestamps for the agent
/// and then the timestamps for the user, they need to be congruent"). `detail` is a second tooltip
/// line under the exact time (a reply's Worked for and tokens). Every label shares one page timer
/// (clock.ts useLabelClock, ui/pageClock.ts subscribePageDeadline), woken only at the nearest minute
/// some label's words change; a date from an earlier year holds none.
export function MessageTime({ at, className, detail }: { at: number; className: string; detail?: string }) {
  const now = useLabelClock(at, nextMessageAge);
  const language = usePaneLanguage();
  const exact = exactTime(at, language);
  return (
    <time
      className={className}
      dateTime={new Date(at).toISOString()}
      /* tooltip-allow: the row shows the age; the tooltip gives the exact date and time, as Claude's */ title={exact}
      data-tooltip-side="top"
      data-tooltip-detail={detail}
      /* The widest age of its first hour, in this language: the prompt row reserves its width in
         the real font (conversation.css .cv-user__time::before), so the minute's words change in place. */
      data-age-widest={messageAge(at, at + 59 * 60_000, language)}
    >
      {messageAge(at, now, language)}
    </time>
  );
}

/// A reply's time at the end of its action row, after the buttons, hidden at rest and shown while the
/// reader points at the reply (conversation.css `.cv-turn-time`; Leo, 2026-11-02: "notice how on
/// hover it reveals the exact timestamp"): the same relative age a prompt's row writes, its exact
/// date and time on hover (Leo, 2026-11-08: "Right now it's just, like in our app, only the user has
/// that sort of relative time thing. The agent in ours only has the exact timestamp."), with
/// `detail` (the turn's time and tokens) on the tooltip's second line when given.
export function ReplyTime({ at, detail }: { at: number; detail?: string }) {
  return <MessageTime at={at} className="cv-turn-time" detail={detail} />;
}

/// Shared footer rail for sent, received and answer rows. Timestamp text and every action stay on
/// one centered 24px line with equal control slots, including the retry model chevron.
export function MessageFooterRow({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={["cv-message-footer-row", className].filter(Boolean).join(" ")}>{children}</span>;
}

/// The dot between a prompt's age and its buttons (Leo's spec for the row under a prompt).
export function MessageDot() {
  return (
    <span className="cv-user__dot" aria-hidden="true">
      ·
    </span>
  );
}

/// Copy through CopyButton (its name as a tooltip, a check once the clipboard took the text), at the
/// row's compact size. The message goes as Claude's and ChatGPT's do: its Markdown as the plain text
/// and its HTML beside it, so Notes, Slack, Docs and Mail paste its headings, bullets and code
/// (richClipboard.ts).
export function MessageCopy({ text }: { text: string }) {
  const t = useT();
  return (
    <CopyButton
      text={text}
      label={t("turn.copy")}
      className="cv-iconbtn cv-iconbtn--compact"
      size={ROW_ICON}
      copy={copyMarkdownResult}
    />
  );
}

/// Fork from here, with Claude's tooltip: the title, then that this chat stays as it is. The host
/// operation can take long enough to look inert, so press feedback starts before the promise is
/// dispatched and a ref closes the same-frame duplicate-click window.
export function ForkButton({ onFork, throughSeq }: { onFork(): unknown; throughSeq?: number }) {
  const t = useT();
  const inFlight = useRef(false);
  const [state, setState] = useState<"idle" | "pending" | "done" | "failed">("idle");
  const readOnly = useTranscriptReadOnly();
  const label =
    state === "pending"
      ? `${t("turn.fork")}…`
      : state === "done"
        ? `${t("turn.fork")} ✓`
        : state === "failed"
          ? t("notice.forkFailed")
          : t("turn.fork");
  const fork = () => {
    if (inFlight.current) return;
    inFlight.current = true;
    setState("pending");
    let result: unknown;
    try {
      result = onFork();
    } catch {
      inFlight.current = false;
      setState("failed");
      return;
    }
    if (!result || typeof (result as PromiseLike<unknown>).then !== "function") {
      inFlight.current = false;
      setState("done");
      return;
    }
    Promise.resolve(result).then(
      () => {
        inFlight.current = false;
        setState("done");
      },
      () => {
        inFlight.current = false;
        setState("failed");
      },
    );
  };
  if (readOnly) return null;
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-fork-button"
      aria-label={label}
      title={label}
      aria-busy={state === "pending"}
      data-fork-state={state}
      disabled={state === "pending"}
      data-tooltip-detail={t("turn.forkDetail")}
      onClick={(event) => {
        if (event.altKey && throughSeq !== undefined && openForkMenu(throughSeq, event.currentTarget)) return;
        fork();
      }}
    >
      {state === "pending" ? (
        <Spinner size={ROW_ICON} loading />
      ) : state === "done" ? (
        <Check size={ROW_ICON} />
      ) : state === "failed" ? (
        <AlertCircle size={ROW_ICON} />
      ) : (
        <TurnFork size={ROW_ICON} />
      )}
    </button>
  );
}

/// Pins the message (row `rowId`): kept with the chat by acpmux; a pinned prompt also shows in the
/// thread minimap. Nothing for a message acpmux has not logged yet.
export function PinButton({ rowId, bookmark = false }: { rowId: string; bookmark?: boolean }) {
  const t = useT();
  const mark = useRowMark({ id: rowId });
  const readOnly = useTranscriptReadOnly();
  if (!mark.can || readOnly) return null;
  const label = t(
    bookmark
      ? mark.marked
        ? "minimap.bookmarkRemove"
        : "minimap.bookmarkAdd"
      : mark.marked
        ? "message.unpin"
        : "message.pin",
  );
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-message-pin"
      aria-pressed={mark.marked}
      aria-label={label}
      title={label}
      onClick={mark.toggle}
    >
      {bookmark ? <BookmarkIcon size={ROW_ICON} filled={mark.marked} /> : <Pin size={ROW_ICON} filled={mark.marked} />}
    </button>
  );
}

/// More (…): opens the menu a right-click on message row `rowId` opens (Quote in Reply, Copy as
/// Plain Text, Edit and Resend, Fork from Here, Open in Side Chat, Open Link...), under the button,
/// so every message action shows on hover (Leo, 2026-10-22). The host builds the menu from the
/// right-click's report (messageMenu.ts); nothing where no host shows that menu.
export function MessageMore({ rowId }: { rowId: string }) {
  const t = useT();
  const readOnly = useTranscriptReadOnly();
  if (!hasMessageMenuHost() || readOnly) return null;
  const label = t("message.moreMenu");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-haspopup="menu"
      aria-label={label}
      title={label}
      onClick={(event) => openMessageMenu(rowId, event.currentTarget)}
    >
      <Icon name="action.more" size={ROW_ICON} />
    </button>
  );
}

/// Reads the message aloud with the system voice; pressed again (or Escape), stops. While it reads
/// it shows a stop glyph and keeps its row shown (conversation.css), so Stop is always in reach.
export function ReadAloudButton({ id, text }: { id: string; text: string }) {
  const t = useT();
  const language = usePaneLanguage();
  const reading = useReadingAloud(id);
  if (!canReadAloud()) return null;
  const label = t(reading ? "message.stopReading" : "message.readAloud");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-read-aloud"
      aria-pressed={reading}
      aria-label={label}
      title={label}
      data-reading={reading || undefined}
      onClick={() => readAloud(id, text, language)}
    >
      {reading ? <StopReading size={ROW_ICON} /> : <Speaker size={ROW_ICON} />}
    </button>
  );
}

/// A prompt's read receipt, as Claude Code desktop's: nothing while it is on its way (its delivery
/// says "sending"; PromptDelivery.tsx draws the clock), one check once acpmux holds it (a steer
/// waiting for the agent's step to end, or a prompt the agent has not started on), two once the
/// agent read it, "Read by Claude Code" on hover (the chat harness's name).
export function ReadReceipt({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const { route } = useContext(TurnActionsContext);
  const delivery = row.delivery;
  if (row.failed || (delivery ? delivery.state === "sending" || delivery.state === "failed" : row.pending)) return null;
  const waiting = row.steer === "waiting";
  const read = !waiting && (!delivery || delivery.state === "read");
  const agent = route?.name;
  const label = read
    ? agent
      ? t("message.readBy", { agent })
      : t("message.readByAgent")
    : t(waiting ? "message.deliveredAtStepEnd" : "message.deliveredNotRead");
  return (
    <span
      className={`cv-user__read${read ? "" : " is-unread"}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an icon with a spoken state, not an image file.
      role="img"
      aria-label={label}
      title={label}
      data-read={read ? "true" : "false"}
    >
      {read ? <DoubleCheck size={ROW_ICON} /> : <Check size={ROW_ICON} />}
    </span>
  );
}

/// Retry, and Retry with another model when the harness has several: sends prompt row `rowId`
/// (`prompt`, as the agent got it) again. Only the Messages view's prompts draw it, sent or queued;
/// in the transcript the last turn's Retry is its reply footer's (TurnRows.tsx TurnFooter).
/// `hasAttachment`: the prompt carries attachments that can all go again, so an attachment-only
/// prompt (no text) still gets Retry.
/// `held`: the prompt is a steer the agent has not read yet (PendingSteer.tsx's row). Its Retry
/// stays in the row, as the sent row's does, but cannot be pressed and has no model menu: a resend
/// while the steer still waits would reach the agent twice (cmux#34613, #34614).
export function PromptRetry({
  rowId,
  prompt,
  hasAttachment = false,
  held = false,
}: {
  rowId: string;
  prompt: string;
  hasAttachment?: boolean;
  held?: boolean;
}) {
  const t = useT();
  const { retry, retryWith } = useContext(TurnActionsContext);
  const readOnly = useTranscriptReadOnly();
  if (!retry || (!prompt && !hasAttachment) || readOnly) return null;
  return (
    <span className="cv-message-retry">
      <button
        type="button"
        className="cv-iconbtn cv-iconbtn--compact"
        aria-label={t("turn.retry")}
        title={t("turn.retry")}
        data-tooltip-detail={t("turn.retryLabel")}
        disabled={held}
        onClick={() => retry(rowId, prompt)}
      >
        <Retry size={ROW_ICON} />
      </button>
      {!held && retryWith && retryWith.models.length > 1 && (
        <RetryModelMenu retryWith={retryWith} onPick={(model) => retryWith.retry(rowId, prompt, model)} />
      )}
    </span>
  );
}

/// A Chief prompt uses the same exclusive queue controls and normal hover actions as a user prompt.
export function PromptActions({
  row,
  text,
  pending,
}: {
  row: AcpmuxRow;
  text: string;
  pending?: (actions: ReactNode, queued: QueuedActions) => ReactNode;
}) {
  // Retry is the last turn's reply footer's (TurnFooter), but the Messages view draws no footer for a
  // turn that ended well, so its prompts, sent or queued, keep Retry there; and a prompt whose turn's
  // footer draws none keeps it too (turns.ts retryPlacement).
  const messagesView = useContext(PresentationContext) === "messages";
  const retryTarget = useContext(RetryTargetContext);
  const canResend = Boolean(useContext(TurnActionsContext).retry);
  const readOnly = useTranscriptReadOnly();
  const promptRetry =
    messagesView ||
    (retryTarget?.promptId === row.id &&
      retryPlacement(retryTarget, { canRetry: canResend, readOnly, messages: false }) === "prompt");
  const prompt = row.resend ?? row.text ?? "";
  // An attachment-only prompt (turns.ts offersRetry) retries when all its attachments can go again.
  const retryProps = { rowId: row.id, prompt, hasAttachment: resendsAttachments(row) };
  const actions = (
    <MessageFooterRow>
      <MessageTime at={row.at} className="cv-user__time" />
      <MessageCopy text={text} />
      {promptRetry && <PromptRetry {...retryProps} />}
      <PinButton rowId={row.id} bookmark />
    </MessageFooterRow>
  );
  return (
    <div className="cv-user__actions">
      {pending ? pending(actions, { retry: promptRetry ? <PromptRetry {...retryProps} held /> : null }) : actions}
    </div>
  );
}

/// The hover row at the end of a message this agent sent another one (MessageCard.tsx): Copy,
/// kept clear of the line's words.
export function SentActions({ text }: { text: string }) {
  return (
    <span className="cv-sent-actions">
      <MessageFooterRow>
        <MessageCopy text={text} />
      </MessageFooterRow>
    </span>
  );
}

/// The row at the end of another agent's message line (IncomingMessageCard.tsx IncomingMessageLine):
/// its age, then `more` (a waiting steer's ⋯, QueuedMessageCard.tsx) in the same group,
/// never a second one beside it. No read receipt: the message is the agent's to read. No Pin and no
/// hover Copy: another session's message is no prompt of this chat's to pin, and the opened card's
/// corner Copy (CardCopy) and the right-click menu copy it (Leo, 2026-10-30: "all these weird button
/// stuff from messages from other sessions... weird to be able to pin them etc").
export function ReceivedActions({ row, more }: { row: AcpmuxRow; more?: ReactNode }) {
  return (
    <>
      <span className="cv-received-actions">
        <MessageFooterRow>
          <MessageTime at={row.at} className="cv-user__time" />
          {more}
        </MessageFooterRow>
      </span>
    </>
  );
}

/// The row under a reply that its turn's footer does not serve (model.ts `hasReplyActions`: a
/// steer, another agent's message, a sent message or a tool row follows it): the footer's look and
/// buttons for this reply, Copy, Pin, Read aloud and More, then its time (shown on hover), as Claude desktop draws
/// under every reply. Its line is reserved; it shows on hover or keyboard focus (conversation.css).
export function ReplyActions({ row }: { row: AcpmuxRow }) {
  const text = row.text ?? "";
  return (
    // Over a status row this line is the reply's whole bottom room (conversation.css
    // `--cv-status-gap`), so its own blank box, never its buttons, is a transcript gap a drag
    // can start from (gutterSelect.ts).
    <div className="cv-turn-actions cv-reply-actions" data-transcript-gap="blank">
      <span className="cv-turn-action-group">
        <MessageCopy text={text} />
        <PinButton rowId={row.id} />
        <ReadAloudButton id={row.id} text={text} />
        <RowReplyButton text={text} />
        <MessageMore rowId={row.id} />
      </span>
      <ReplyTime at={row.at} />
    </div>
  );
}
