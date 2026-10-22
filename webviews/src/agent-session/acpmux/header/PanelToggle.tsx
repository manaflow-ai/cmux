// The header's right-side panel toggle: the first of its icons, as Claude and ChatGPT desktop's is.
// One glyph whoever owns the panel (the summary, summary/SummaryButton.tsx; the Inspector,
// inspector/ChatInspector.tsx): a frame with one divider, its column filled and the button pressed
// while the panel is open.
import { Icon } from "../icons/Icon";
import { HEADER_GLYPH } from "./ChatHeaderTools";
import { tooltipProps } from "../shortcuts";

export function PanelToggle({
  label,
  shown,
  onToggle,
  className,
}: {
  label: string;
  shown: boolean;
  onToggle: () => void;
  /// The owner's own class, which automation and captures click it by.
  className?: string;
}) {
  return (
    <button
      type="button"
      className={`acpmux-header-tool acpmux-header-panel-toggle${className ? ` ${className}` : ""}`}
      aria-label={label}
      aria-pressed={shown}
      {...tooltipProps(label, undefined)}
      onClick={onToggle}
    >
      <Icon name="panel.right" size={HEADER_GLYPH} selected={shown} />
    </button>
  );
}
