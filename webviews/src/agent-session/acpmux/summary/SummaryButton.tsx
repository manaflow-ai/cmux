import { useContext, useEffect } from "react";
import { PanelToggle } from "../header/PanelToggle";
import { useT } from "../i18n";
import { ChatViewParked, registerPicker } from "../pickerOpeners";
import type { SummaryCardControl } from "./cardState";

/// The header's summary button: shows or hides the chat's summary card (SummaryCard.tsx), which
/// stays at the pane's top right until it is hidden here or by its own close button. It is the
/// header's panel toggle (header/PanelToggle.tsx), the first of its icons.
export function SummaryButton({ card, native = false }: { card: SummaryCardControl; native?: boolean }) {
  const t = useT();
  const label = t("summary.open");
  // Automation and captures show it by its label, as a click does (see pickerOpeners.ts).
  const show = card.show;
  const parked = useContext(ChatViewParked);
  useEffect(() => (parked ? undefined : registerPicker(label, show)), [label, show, parked]);
  // Keep the picker registration when the native host owns only the visible button.
  if (native) return null;
  return <PanelToggle className="acpmux-summary-button" label={label} shown={card.shown} onToggle={card.toggle} />;
}
