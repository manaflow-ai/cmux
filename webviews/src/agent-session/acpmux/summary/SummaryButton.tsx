import React, { useEffect } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { registerPicker } from "../pickerOpeners";
import type { SummaryCardControl } from "./cardState";

/// The header's summary button: opens or closes the chat's summary (SummaryCard.tsx), the card
/// pinned under it. `covered`: a side view (Inspector, diff review, replay, Harnesses) takes the
/// card's place, so the button has nothing to open or close.
export function SummaryButton({ card, covered = false }: { card: SummaryCardControl; covered?: boolean }) {
  const t = useT();
  const label = t("summary.open");
  // Automation and captures show it by its label, as a click does (see pickerOpeners.ts).
  const show = card.show;
  useEffect(() => registerPicker(label, show), [label, show]);
  return (
    <span className="acpmux-summary">
      <button
        type="button"
        className="acpmux-summary-button"
        aria-label={label}
        title={label}
        disabled={covered}
        aria-expanded={card.shown && !covered}
        aria-controls={card.shown && !covered ? card.id : undefined}
        onClick={card.toggle}
      >
        <Icon name="view.list" size={15} />
      </button>
    </span>
  );
}
