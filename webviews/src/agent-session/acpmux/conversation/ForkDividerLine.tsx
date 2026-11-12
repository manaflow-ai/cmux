// A fork's cut in the transcript (conversation/forkDivider.ts): a hairline across the column with
// "Forked from Claude Opus 5.5" at its middle, and for a model switch shown in this pane a quiet
// Open in new tab after it. One line of text the height of any notice, so the transcript's
// measured rhythm does not move.
import { useT } from "../i18n";
import type { ForkDivider } from "./forkDivider";

/// `look`: the shipped hairline, or the gallery's chip arm (the label in a pill on the line).
export function ForkDividerLine({
  divider,
  onOpenInTab,
  look = "hairline",
}: {
  divider: ForkDivider;
  onOpenInTab?: (target: NonNullable<ForkDivider["openInTab"]>) => void;
  look?: "hairline" | "chip";
}) {
  const t = useT();
  const target = divider.openInTab;
  return (
    <div className="cv-fork-divider" data-look={look}>
      <span className="cv-fork-divider__rule" aria-hidden="true" />
      <span className="cv-fork-divider__label">{divider.label}</span>
      {target && onOpenInTab && (
        <button type="button" className="cv-fork-divider__action" onClick={() => onOpenInTab(target)}>
          {t("forkDivider.openInTab")}
        </button>
      )}
      <span className="cv-fork-divider__rule" aria-hidden="true" />
    </div>
  );
}
