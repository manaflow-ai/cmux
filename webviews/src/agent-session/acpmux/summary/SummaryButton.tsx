import React, { useEffect } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { registerPicker } from "../pickerOpeners";
import { SUMMARY_PANEL_ID } from "./PinnedSummaryCard";
import { useSummaryOpen } from "./summaryPin";

/// The header's summary button (PINNED-SUMMARY P1'): it opens and closes the docked summary panel
/// (PinnedSummaryCard.tsx SummaryDock). It never opens a popover: the panel stays open until the user closes
/// it here, with the panel's close button, or with Escape inside the panel. Automation opens the panel by the
/// button's label, as a click does (pickerOpeners.ts); opening by automation never closes it.
export function SummaryButton() {
  const t = useT();
  const { open, setOpen } = useSummaryOpen();
  const label = t("summary.open");
  useEffect(() => registerPicker(label, () => setOpen(true)), [label, setOpen]);
  return (
    <span className="acpmux-summary">
      <button
        type="button"
        data-summary-toggle
        className="acpmux-summary-button"
        aria-label={label}
        title={open ? t("summary.close") : label}
        aria-expanded={open}
        aria-controls={open ? SUMMARY_PANEL_ID : undefined}
        aria-pressed={open}
        onClick={() => setOpen(!open)}
      >
        <Icon name="view.list" size={15} />
      </button>
    </span>
  );
}
