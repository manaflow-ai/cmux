// The buttons of a message's action row, shared by a prompt's (UserBubble.tsx) and an answer's
// (TurnRows.tsx TurnFooter), as Claude Code desktop draws them: the message's age ("8 minutes
// ago", its date and time on hover), Copy, Fork from here (its title and what it does), Pin and
// Read aloud. The rows show on hover or keyboard focus only (conversation.css).
import { useState } from "react";
import { useMinuteClock } from "../clock";
import { usePaneLanguage, useT } from "../i18n";
import { useRowMark } from "../threadMinimap/promptMarks";
import { copyText } from "./clipboard";
import { Copy, Pin, Speaker, TurnFork } from "./icons";
import { canReadAloud, readAloud, useReadingAloud } from "./readAloud";
import { relativeTime } from "./relativeTime";

/// The message's age, relative and live; the exact date and time on hover.
export function MessageTime({ at, className }: { at: number; className: string }) {
  const now = useMinuteClock();
  const language = usePaneLanguage();
  const exact = new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(at);
  return (
    <time className={className} dateTime={new Date(at).toISOString()} title={exact}>
      {relativeTime(at, now, language)}
    </time>
  );
}

export function CopyButton({ text }: { text: string }) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const label = copied ? t("turn.copied") : t("turn.copy");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact"
      aria-label={label}
      title={label}
      onClick={() =>
        void copyText(text).then(
          () => setCopied(true),
          () => setCopied(false),
        )
      }
    >
      <Copy size={14} />
    </button>
  );
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

/// Pins the message (row `rowId`): kept with the chat by acpmux, listed in the thread minimap.
/// Nothing for a message acpmux has not logged yet.
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
