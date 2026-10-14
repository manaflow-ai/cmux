import React, { useEffect } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { registerPicker } from "../pickerOpeners";
import type { SummaryCardControl } from "./cardState";

/// The header's summary button: shows or hides the chat's summary (SummaryCard.tsx), the panel
/// docked beside the chat or, in a narrow pane, its popover. `covered`: a side view (Inspector,
/// diff review, replay, Harnesses) takes the docked panel's place, so the button has nothing to show or hide.
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
        // A docked panel is a toggle; a popover is one this button expands.
        {...(card.docked
          ? { "aria-pressed": card.shown && !covered }
          : { "aria-expanded": card.shown, "aria-controls": card.shown ? card.id : undefined })}
        onClick={card.toggle}
      >
        <Icon name="view.list" size={15} />
      </button>
    </span>
  );
}
