import { DismissButton } from "../../../ui/DismissButton";
import { Icon } from "../icons/Icon";

/// The card's close: the shared × (ui/DismissButton.tsx) drawn with the pack's close, as the pager's
/// chevrons are, so the bar's icons share one stroke and size at every density (#56534). Its tooltip
/// opens above the bar, never over the question.
export function CardDismiss({ label, onDismiss }: { label: string; onDismiss(): void }) {
  return (
    <DismissButton
      label={label}
      onDismiss={onDismiss}
      tooltipSide="top"
      glyph={<Icon name="action.close" size={12} />}
    />
  );
}
