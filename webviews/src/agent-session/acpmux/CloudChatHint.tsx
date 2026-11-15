import { useState } from "react";
import { motionMode } from "../../ui/motion/motionMode";
import { EnvironmentIcon } from "./EnvironmentPicker";
import { useT } from "./i18n";
import "./cloudChatHint.css";

/// How the hint draws (CloudChatHint.gallery.tsx compares them): `line`, one quiet row over the
/// composer with Use Cloud and an X (shipped); `card`, a title and a sentence on a tonal block with
/// the actions beside them; `chip`, one tonal pill, Try Cloud and an X, and nothing else.
export type CloudChatHintLook = "line" | "card" | "chip";

/// The one-time Cloud hint over a new chat's composer (cloudChatHintModel.ts says when it shows and
/// where its record lives). It never covers the composer: it is a row in the column above it, and
/// it opens and closes by its own height on the house settle (--cmux-ease-settle over
/// --cmux-motion-settle), so the composer moves with it in one transition and nothing pops in
/// after. Use Cloud runs the Where menu's own Cloud pick (`onUse`); the X closes it for this
/// install (`onClose`). Either one first folds the row away, then calls back.
export function CloudChatHint({
  look = "line",
  onUse,
  onClose,
}: {
  look?: CloudChatHintLook;
  onUse(): void;
  onClose(): void;
}) {
  const t = useT();
  // The answer waits for the fold to end, so the row leaves on its own curve and the composer
  // settles under it; reduced motion has no animation, and the answer comes at once.
  const [leaving, setLeaving] = useState<(() => void) | undefined>(undefined);
  const leave = (then: () => void) => {
    if (leaving) return;
    if (motionMode() !== "full") return then();
    setLeaving(() => then);
  };
  return (
    <div
      className="acpmux-cloud-hint-fold"
      data-leaving={leaving ? "true" : undefined}
      onAnimationEnd={(event) => {
        if (event.target === event.currentTarget && leaving) leaving();
      }}
    >
      <div className="acpmux-cloud-hint-clip">
        <aside className="acpmux-cloud-hint" data-look={look} aria-label={t("cloudHint.label")}>
          <span className="acpmux-cloud-hint-icon" aria-hidden="true">
            <EnvironmentIcon kind="cloud" />
          </span>
          {look === "chip" ? null : (
            <span className="acpmux-cloud-hint-text">
              {look === "card" && <strong className="acpmux-cloud-hint-title">{t("cloudHint.title")}</strong>}
              <span className="acpmux-cloud-hint-body">{t("cloudHint.body")}</span>
            </span>
          )}
          <button
            type="button"
            className="acpmux-cloud-hint-use"
            data-testid="cloud-hint-use"
            onClick={() => leave(onUse)}
          >
            {t(look === "chip" ? "cloudHint.try" : "cloudHint.use")}
          </button>
          <button
            type="button"
            className="acpmux-cloud-hint-close"
            data-testid="cloud-hint-close"
            aria-label={t("cloudHint.close")}
            data-tooltip={t("cloudHint.close")}
            onClick={() => leave(onClose)}
          >
            <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
              <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          </button>
        </aside>
      </div>
    </div>
  );
}
