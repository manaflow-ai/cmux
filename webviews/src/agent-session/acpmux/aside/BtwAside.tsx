import { RevealedMarkdown } from "../conversation/RevealedMarkdown";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import type { BtwNote } from "./btwNotes";
import "./btw.css";

export function BtwAside({ note, onDismiss }: { note: BtwNote; onDismiss(): void }) {
  const t = useT();
  const pending = note.answer === undefined && note.error === undefined;
  return (
    <aside className="acpmux-btw-note" aria-label={t("sideQuestion.label")} aria-busy={pending} aria-live="polite">
      <header className="acpmux-btw-head">
        <span className="acpmux-btw-label">{t("sideQuestion.label")}</span>
        <button type="button" className="acpmux-btw-dismiss" aria-label={t("sideQuestion.dismiss")} onClick={onDismiss}>
          <Icon name="action.close" size={14} />
        </button>
      </header>
      <p className="acpmux-btw-question">{note.question}</p>
      {pending ? (
        <p className="acpmux-btw-status">{t("needsYou.asking")}</p>
      ) : note.error !== undefined ? (
        <p role="alert">
          {t("needsYou.askFailed")}
          {note.error ? `: ${note.error}` : ""}
        </p>
      ) : (
        <RevealedMarkdown text={note.answer ?? ""} streaming={false} />
      )}
    </aside>
  );
}
