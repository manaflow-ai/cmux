// The header's right-side panel toggle: the first of its icons, as Claude and ChatGPT desktop's is.
// One glyph whoever owns the panel (the summary, summary/SummaryButton.tsx; the Inspector,
// inspector/ChatInspector.tsx). The open panel reads as pressed through its ink and selected glyph,
// keeping the same quiet surface as the other header controls (header.css).
import { Icon } from "../icons/Icon";
import { HEADER_GLYPH } from "./ChatHeaderTools";
import { tooltipProps } from "../shortcuts";

export function PanelToggle({
  label,
  shown,
  onToggle,
  className,
  icon = "view.list",
}: {
  label: string;
  shown: boolean;
  onToggle: () => void;
  /// The owner's own class, which automation and captures click it by.
  className?: string;
  /// Gallery-only alternatives keep the design choice visible without changing the shipped default.
  icon?: string;
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
      <Icon name={icon} size={HEADER_GLYPH} selected={shown} />
    </button>
  );
}
