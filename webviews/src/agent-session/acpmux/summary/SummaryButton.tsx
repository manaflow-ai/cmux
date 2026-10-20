import React, { useEffect } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { registerPicker } from "../pickerOpeners";
import type { SummaryCardControl } from "./cardState";

/// The header's summary button: shows or hides the chat's summary card (SummaryCard.tsx), which
/// stays at the pane's top right until it is hidden here or by its own close button.
export function SummaryButton({ card }: { card: SummaryCardControl }) {
  const t = useT();
  const label = t("summary.threadDetails");
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
        aria-pressed={card.shown}
        onClick={card.toggle}
      >
        <Icon name="view.list" size={15} />
      </button>
    </span>
  );
}
