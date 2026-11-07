// A session recap (acpmux `recap` record, `hub/away_recap.rs`): when the person comes back to a
// Claude chat after 5+ minutes away, a line or two on where it stands, in Claude Code's own recap
// words (Leo, 2026-11-03: "lkewise with teh cli summarization thing? how do those get turned on?
// maybe we can expose it in cmux-next too"). Not a user or assistant bubble: a quiet hairline
// card with a ×, like Claude's own recap card (cmux-design-references
// claude/web/october-recap-card). The daemon decides when; this only draws it. Its × drops the row
// (direct.ts dismissRecap), and it stays dismissed on this device (recapDismissed.ts).
// `agents.chats.sessionRecap` turns recaps off.
import { useT } from "../i18n";
import type { AcpmuxRecap } from "../model";
import { Close } from "./icons";

/// How the recap is drawn: a hairline card with a × (shipped), a tool-row line, or a rule on the
/// left. The gallery compares them (RecapNote.gallery.ts).
export type RecapLook = "card" | "line" | "rule";

export function RecapNote({
  recap,
  onDismiss,
  look = "card",
}: {
  recap: AcpmuxRecap;
  onDismiss: () => void;
  look?: RecapLook;
}) {
  const t = useT();
  return (
    <div className="cv-recap" data-look={look} role="note">
      <p className="cv-recap__text">
        <span className="cv-recap__label">{t("awayRecap.label")}</span>
        <span className="cv-recap__sep" aria-hidden="true">
          {" · "}
        </span>
        {recap.text}
      </p>
      <button
        type="button"
        className="cv-recap__close"
        aria-label={t("awayRecap.dismiss")}
        title={t("awayRecap.dismiss")}
        onClick={onDismiss}
      >
        <Close />
      </button>
    </div>
  );
}
