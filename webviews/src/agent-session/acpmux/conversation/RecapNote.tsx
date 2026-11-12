// A session recap (acpmux `recap` record, `hub/away_recap.rs`): when the person comes back to a
// chat after 5+ minutes away, a line or two on the goal and the next step (Leo, 2026-11-03:
// "lkewise with teh cli summarization thing? how do those get turned on? maybe we can expose it in
// cmux-next too"; 2026-11-12: "and also a gui enableable recap feature"). Not a user or assistant
// bubble: Claude Code's own quiet italic "※ recap:" line, on tokens only (design/transcript-overlays.md
// "Session recap"). The daemon decides when; this only draws it. Its × drops the row (direct.ts
// dismissRecap), and it stays dismissed on this device (recapDismissed.ts). Settings > Chats >
// Session Recap (`agents.chats.sessionRecap`) turns recaps off, and hides any already drawn
// (chatDisplay.ts useSessionRecapOn).
import { useT } from "../i18n";
import type { AcpmuxRecap } from "../model";
import { Close } from "./icons";

/// How the recap is drawn. `terminal` (shipped): Claude Code's line, "※ recap:" then the text, all
/// italic and dim, its × showing on hover or focus. `plain`: the same line with no lead. `mark`: the
/// ※ alone as the lead. `card`, `line`, `rule`: the earlier hairline card and its two rivals. The
/// gallery compares them (RecapNote.gallery.tsx).
export type RecapLook = "terminal" | "plain" | "mark" | "card" | "line" | "rule";

/// The looks drawn as Claude Code's terminal line: italic, dim, the × quiet until hovered.
const TERMINAL_LOOKS: ReadonlySet<RecapLook> = new Set(["terminal", "plain", "mark"]);

export function RecapNote({
  recap,
  onDismiss,
  look = "terminal",
  lead = true,
}: {
  recap: AcpmuxRecap;
  /// The ×. Without it (a read-only or replayed transcript) the recap draws no ×.
  onDismiss?: () => void;
  look?: RecapLook;
  /// The card looks' "While you were away" before the text; off under "New since you looked"
  /// (SinceDivider.tsx), which says it already. The terminal looks keep their "※ recap:".
  lead?: boolean;
}) {
  const t = useT();
  const terminal = TERMINAL_LOOKS.has(look);
  return (
    <div className="cv-recap" data-look={look} data-terminal={terminal ? "" : undefined} role="note">
      <p className="cv-recap__text">
        {terminal
          ? look !== "plain" && (
              <span className="cv-recap__label">
                <span className="cv-recap__mark" aria-hidden="true">
                  ※
                </span>
                {look === "terminal" && <>{` ${t("awayRecap.short")}:`}</>}{" "}
              </span>
            )
          : lead && (
              <>
                <span className="cv-recap__label">{t("awayRecap.label")}</span>
                <span className="cv-recap__sep" aria-hidden="true">
                  {" · "}
                </span>
              </>
            )}
        {recap.text}
      </p>
      {onDismiss && (
        <button
          type="button"
          className="cv-recap__close"
          aria-label={t("awayRecap.dismiss")}
          title={t("awayRecap.dismiss")}
          onClick={onDismiss}
        >
          <Close />
        </button>
      )}
    </div>
  );
}
