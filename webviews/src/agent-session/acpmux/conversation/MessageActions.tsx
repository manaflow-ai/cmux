// The buttons of a message's action row, shared by a prompt's (UserBubble.tsx, PromptActions for
// the Chief's), another agent's message's (ReceivedActions) and an answer's (TurnRows.tsx TurnFooter), as Claude Code desktop
// draws them: the message's age ("8 minutes ago", its date and time on hover), a prompt's read
// receipt, Copy, Retry, Fork from here (its title and what it does), Pin and Read aloud. The rows
// show on hover or keyboard focus only (conversation.css).
import { useContext } from "react";
import { useMinuteClock } from "../clock";
import { usePaneLanguage, useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { useRowMark } from "../threadMinimap/promptMarks";
import { Check, DoubleCheck, Pin, Retry, Speaker, TurnFork } from "./icons";
import { canReadAloud, readAloud, useReadingAloud } from "./readAloud";
import { relativeTime } from "./relativeTime";
import { CopyButton } from "./CopyButton";
import { RetryModelMenu } from "./RetryModelMenu";
import { TurnActionsContext } from "./turnActions";

/// The message's age, relative and live; the exact date and time on hover.
export function MessageTime({ at, className }: { at: number; className: string }) {
  const now = useMinuteClock();
  const language = usePaneLanguage();
  const exact = new Intl.DateTimeFormat(language, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(at);
  return (
    <time
      className={className}
      dateTime={new Date(at).toISOString()}
      /* tooltip-allow: the row shows the age; the tooltip gives the exact date and time, as Claude's */ title={exact}
    >
      {relativeTime(at, now, language)}
    </time>
  );
}

/// Copy through CopyButton (its name as a tooltip, a check once the clipboard took the text), at the
/// row's compact size.
export function MessageCopy({ text }: { text: string }) {
  const t = useT();
  return <CopyButton text={text} label={t("turn.copy")} className="cv-iconbtn cv-iconbtn--compact" size={14} />;
}

/// Fork from here, with Claude's tooltip: the title, then that this chat stays as it is.
export function ForkButton({ onFork }: { onFork(): void }) {
  const t = useT();
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-label={t("turn.fork")}
      title={t("turn.fork")}
      data-tooltip-detail={t("turn.forkDetail")}
      onClick={onFork}
    >
      <TurnFork size={14} />
    </button>
  );
}

/// Pins the message (row `rowId`): kept with the chat by acpmux; a pinned prompt also shows in the
/// thread minimap. Nothing for a message acpmux has not logged yet.
export function PinButton({ rowId }: { rowId: string }) {
  const t = useT();
  const mark = useRowMark({ id: rowId });
  if (!mark.can) return null;
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
      <Pin size={14} filled={mark.marked} />
    </button>
  );
}

/// Reads the message aloud with the system voice; pressed again, stops.
export function ReadAloudButton({ id, text }: { id: string; text: string }) {
  const t = useT();
  const language = usePaneLanguage();
  const reading = useReadingAloud(id);
  if (!canReadAloud()) return null;
  const label = t(reading ? "message.stopReading" : "message.readAloud");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-pressed={reading}
      aria-label={label}
      title={label}
      onClick={() => readAloud(id, text, language)}
    >
      <Speaker size={14} />
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
      {read ? <DoubleCheck size={14} /> : <Check size={14} />}
    </span>
  );
}

/// Retry, and Retry with another model when the harness has several: sends prompt row `rowId`
/// (`prompt`, as the agent got it) again. It shows on the last ended turn's prompt only
/// (VirtualTranscript marks that row `data-retryable`; conversation.css).
export function PromptRetry({ rowId, prompt }: { rowId: string; prompt: string }) {
  const t = useT();
  const { retry, retryWith } = useContext(TurnActionsContext);
  if (!retry || !prompt) return null;
  return (
    <span className="cv-message-retry">
      <button
        type="button"
        className="cv-iconbtn cv-iconbtn--compact"
        aria-label={t("turn.retry")}
        title={t("turn.retryLabel")}
        onClick={() => retry(rowId, prompt)}
      >
        <Retry size={14} />
      </button>
      {retryWith && retryWith.models.length > 1 && (
        <RetryModelMenu retryWith={retryWith} onPick={(model) => retryWith.retry(rowId, prompt, model)} />
      )}
    </span>
  );
}

/// The row under a prompt the Chief sent (ChiefPromptBubble): its age, its read receipt, Copy,
/// Retry and Pin, as under the person's own bubble.
export function PromptActions({ row, text }: { row: AcpmuxRow; text: string }) {
  return (
    <div className="cv-user__actions">
      <MessageTime at={row.at} className="cv-user__time" />
      <ReadReceipt row={row} />
      <MessageCopy text={text} />
      <PromptRetry rowId={row.id} prompt={row.resend ?? row.text ?? ""} />
      <PinButton rowId={row.id} />
    </div>
  );
}

/// The row at the end of another agent's message line (IncomingMessageCard.tsx IncomingMessageLine):
/// its age, Copy, Retry and Pin. No read receipt: the message is the agent's to read.
export function ReceivedActions({ row, text }: { row: AcpmuxRow; text: string }) {
  return (
    <span className="cv-received-actions">
      <MessageTime at={row.at} className="cv-user__time" />
      <MessageCopy text={text} />
      <PromptRetry rowId={row.id} prompt={row.resend ?? row.text ?? ""} />
      <PinButton rowId={row.id} />
    </span>
  );
}
