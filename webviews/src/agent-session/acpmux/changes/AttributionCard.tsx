// Who wrote a changed line: the card a line's marker shows in a chat's edit diff. The newest writer
// first (its chat, or "This chat", then when, the model and the first line of the prompt), then the
// turns that wrote the line before it, one compact row each. A writer in the shown chat scrolls to
// its turn; one in another chat is that turn's cmux link, which the host opens in the app. The
// gallery keeps two other looks (AttributionCard.gallery.tsx): one line, and every writer in full.
import type { FocusEvent, ReactNode } from "react";
import { usePaneLanguage, useT } from "../i18n";
import { relativeTime } from "../conversation/relativeTime";
import { sessionLink } from "../links";
import { initials } from "../../../ui/initials";
import type { Attribution } from "./attribution";
import "./attribution.css";

/// `card` ships; `line` and `stack` are the gallery's other looks.
export type AttributionLook = "card" | "line" | "stack";

type Props = {
  /// The line's writers, newest first (attribution.ts `writersOf`).
  writers: readonly Attribution[];
  /// The chat the pane shows.
  currentSessionId: string | undefined;
  /// Scrolls the shown chat to its turn.
  onReveal(turnId: string): void;
  look?: AttributionLook;
  /// The time ages are read at (the gallery's fixed clock); else when the card renders.
  now?: number;
  onFocus?(): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
};

export function AttributionCardContent({
  writers,
  currentSessionId,
  onReveal,
  look = "card",
  now,
  onFocus,
  onBlur,
}: Props) {
  const t = useT();
  const language = usePaneLanguage();
  // The card reads the time when it opens: it shows for seconds, so it never ticks.
  const at = now ?? Date.now();
  const [newest, ...older] = writers;
  if (!newest) return null;
  const chat = (writer: Attribution) =>
    writer.sessionId === currentSessionId ? t("attribution.thisChat") : (writer.title ?? t("attribution.untitledChat"));
  const ago = (writer: Attribution) => relativeTime(writer.at, at, language);
  const row = (writer: Attribution, className: string, children: ReactNode) => (
    <WriterRow
      key={`${writer.sessionId}\0${writer.turnId}`}
      writer={writer}
      current={writer.sessionId === currentSessionId}
      className={className}
      onReveal={onReveal}
      onFocus={onFocus}
      onBlur={onBlur}
    >
      {children}
    </WriterRow>
  );
  if (look === "line")
    return (
      <div className="cv-attribution" data-look="line">
        {row(
          newest,
          "cv-attribution__writer",
          <span className="cv-attribution__line">
            {[chat(newest), newest.model, newest.prompt, ago(newest)].filter(Boolean).join(" · ")}
          </span>,
        )}
      </div>
    );
  if (look === "stack")
    return (
      <div className="cv-attribution" data-look="stack">
        {writers.map((writer) =>
          row(
            writer,
            "cv-attribution__writer",
            <>
              <span className="cv-attribution__avatar" aria-hidden="true">
                {initials(chat(writer))}
              </span>
              <span className="cv-attribution__body">
                <span className="cv-attribution__head">
                  <span className="cv-attribution__chat">{chat(writer)}</span>
                  <span className="cv-attribution__age">{ago(writer)}</span>
                </span>
                {writer.model && <span className="cv-attribution__model">{writer.model}</span>}
                {writer.prompt && <span className="cv-attribution__prompt">{writer.prompt}</span>}
              </span>
            </>,
          ),
        )}
      </div>
    );
  return (
    <div className="cv-attribution" data-look="card">
      {row(
        newest,
        "cv-attribution__writer",
        <>
          <span className="cv-attribution__head">
            <span className="cv-attribution__chat">{chat(newest)}</span>
            <span className="cv-attribution__age">{ago(newest)}</span>
          </span>
          {newest.model && <span className="cv-attribution__model">{newest.model}</span>}
          {newest.prompt && <span className="cv-attribution__prompt">{newest.prompt}</span>}
        </>,
      )}
      {older.length > 0 && (
        <div className="cv-attribution__older">
          <span className="cv-attribution__label">{t("attribution.earlier")}</span>
          {older.map((writer) =>
            row(
              writer,
              "cv-attribution__older-row",
              <>
                <span className="cv-attribution__chat">{chat(writer)}</span>
                <span className="cv-attribution__meta">{[writer.model, ago(writer)].filter(Boolean).join(" · ")}</span>
              </>,
            ),
          )}
        </div>
      )}
    </div>
  );
}

/// One writer: a button that scrolls to its turn in the shown chat, the turn's link in another chat,
/// or plain text when no link can name it.
function WriterRow({
  writer,
  current,
  className,
  onReveal,
  onFocus,
  onBlur,
  children,
}: {
  writer: Attribution;
  current: boolean;
  className: string;
  onReveal(turnId: string): void;
  onFocus?(): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
  children: ReactNode;
}) {
  if (current)
    return (
      <button
        type="button"
        className={className}
        onClick={() => onReveal(writer.turnId)}
        onFocus={onFocus}
        onBlur={onBlur}
      >
        {children}
      </button>
    );
  const href = sessionLink(writer.sessionId, writer.turnId);
  if (!href) return <div className={className}>{children}</div>;
  // A plain anchor, so the click takes the host's link path (opened in the app).
  return (
    <a className={className} href={href} onFocus={onFocus} onBlur={onBlur}>
      {children}
    </a>
  );
}
