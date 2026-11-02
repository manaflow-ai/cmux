// The buttons of a message's action row, shared by a prompt's (UserBubble.tsx, PromptActions for
// the Chief's), another agent's message's (ReceivedActions) and an answer's (TurnRows.tsx TurnFooter), as Claude Code desktop
// draws them: the message's age ("8 minutes ago"; "Oct 20, 2026, 10:16 PM" above it on hover), a
// prompt's read receipt, Copy, Retry, Fork from here (its title and what it does), Pin, Read
// aloud and More (the message's right-click menu), each glyph ROW_ICON px in a 24 px button. The rows show on hover or keyboard focus only,
// with Claude's fade (conversation.css).
import { useContext, useRef, useState, type ReactNode } from "react";
import { useMinuteClock } from "../clock";
import { usePaneLanguage, useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { useRowMark } from "../threadMinimap/promptMarks";
import { AlertCircle, Check, DoubleCheck, Pin, Retry, Speaker, Spinner, StopReading, TurnFork } from "./icons";
import { canReadAloud, readAloud, useReadingAloud } from "./readAloud";
import { exactTime, relativeTime, replyTime } from "./relativeTime";
import { CopyButton } from "./CopyButton";
import { hasMessageMenuHost, openMessageMenu, openForkMenu } from "./messageMenu";
import { RetryModelMenu } from "./RetryModelMenu";
import { TurnActionsContext } from "./turnActions";
import { useTranscriptReadOnly } from "./readOnly";

/// A hover row's glyph size: Claude's 16 px icons, each in a 24 px (--cv-meta-row) button.
export const ROW_ICON = 16;

/// The message's age, relative and live; the exact date and time above it on hover, as Claude's.
export function MessageTime({ at, className }: { at: number; className: string }) {
  const now = useMinuteClock();
  const language = usePaneLanguage();
  return (
    <time
      className={className}
      dateTime={new Date(at).toISOString()}
      /* tooltip-allow: the row shows the age; the tooltip gives the exact date and time, as Claude's */ title={exactTime(
        at,
        language,
      )}
      data-tooltip-side="top"
    >
      {relativeTime(at, now, language)}
    </time>
  );
}

/// A reply's time at the end of its action row, after the buttons, as ChatGPT's: the exact date and
/// time ("Oct 18, 5:41 AM"), hidden at rest and shown while the reader points at the reply
/// (conversation.css `.cv-turn-time`; Leo, 2026-11-02: "notice how on hover it reveals the exact
/// timestamp. let's follow those."). `detail`, when given, is its tooltip (the turn's time and tokens).
export function ReplyTime({ at, detail }: { at: number; detail?: string }) {
  const now = useMinuteClock();
  const language = usePaneLanguage();
  return (
    <time
      className="cv-turn-time"
      dateTime={new Date(at).toISOString()}
      /* tooltip-allow: the turn's time and tokens, which the row no longer spells out (Leo, 2026-11-02) */ title={
        detail
      }
      data-tooltip-side="top"
    >
      {replyTime(at, now, language)}
    </time>
  );
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
/// row's compact size.
export function MessageCopy({ text }: { text: string }) {
  const t = useT();
  return <CopyButton text={text} label={t("turn.copy")} className="cv-iconbtn cv-iconbtn--compact" size={ROW_ICON} />;
}

/// Use the live host action when the page has one: unlike the turn context's legacy callback, it
/// returns the fork promise so the button can stay pending until the new agent is ready. Gallery
/// and unit-test callers keep their injected fallback.
export function forkWithFeedback(throughSeq: number, fallback: () => unknown): unknown {
  const action = globalThis.window?.cmuxAcpmuxActions?.["chat.fork"];
  if (!action) return fallback();
  return action({ throughSeq }).then((sessionId) => {
    // direct.fork reports refusal by returning no session id after it has written the localized
    // transcript notice; turn that sentinel into the button's terminal error state too.
    // l10n-allow: the button's error state only; the transcript notice already says why.
    if (sessionId === undefined || sessionId === null || sessionId === false) throw new Error("fork failed");
    return sessionId;
  });
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
export function PinButton({ rowId }: { rowId: string }) {
  const t = useT();
  const mark = useRowMark({ id: rowId });
  const readOnly = useTranscriptReadOnly();
  if (!mark.can || readOnly) return null;
  const label = t(mark.marked ? "message.unpin" : "message.pin");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-message-pin"
      aria-pressed={mark.marked}
      aria-label={label}
      title={label}
      onClick={mark.toggle}
    >
      <Pin size={ROW_ICON} filled={mark.marked} />
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
/// (`prompt`, as the agent got it) again. Under a prompt it shows on every one, as Claude's; at the
/// end of another agent's message only on the last ended turn's (VirtualTranscript marks that row
/// `data-retryable`; conversation.css).
export function PromptRetry({ rowId, prompt }: { rowId: string; prompt: string }) {
  const t = useT();
  const { retry, retryWith } = useContext(TurnActionsContext);
  const readOnly = useTranscriptReadOnly();
  if (!retry || !prompt || readOnly) return null;
  return (
    <span className="cv-message-retry">
      <button
        type="button"
        className="cv-iconbtn cv-iconbtn--compact"
        aria-label={t("turn.retry")}
        title={t("turn.retry")}
        data-tooltip-detail={t("turn.retryLabel")}
        onClick={() => retry(rowId, prompt)}
      >
        <Retry size={ROW_ICON} />
      </button>
      {retryWith && retryWith.models.length > 1 && (
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
  pending?: (actions: ReactNode) => ReactNode;
}) {
  const actions = (
    <MessageFooterRow>
      <MessageTime at={row.at} className="cv-user__time" />
      <MessageCopy text={text} />
      <PromptRetry rowId={row.id} prompt={row.resend ?? row.text ?? ""} />
    </MessageFooterRow>
  );
  return <div className="cv-user__actions">{pending ? pending(actions) : actions}</div>;
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
/// its age and Retry, then `more` (a waiting steer's ⋯, QueuedMessageCard.tsx) in the same group,
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
          <PromptRetry rowId={row.id} prompt={row.resend ?? row.text ?? ""} />
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
        <MessageMore rowId={row.id} />
      </span>
      <ReplyTime at={row.at} />
    </div>
  );
}
