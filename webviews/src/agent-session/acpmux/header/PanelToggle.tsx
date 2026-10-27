// The header's right-side panel toggle: the first of its icons, as Claude and ChatGPT desktop's is.
// One glyph whoever owns the panel (the summary, summary/SummaryButton.tsx; the Inspector,
// inspector/ChatInspector.tsx). While the panel is open the button reads as pressed: a soft fill
// behind its glyph (header.css; Leo, 2026-10-26: "why is the button not toggled?").
import { Icon } from "../icons/Icon";
import { HEADER_GLYPH } from "./ChatHeaderTools";
import { tooltipProps } from "../shortcuts";

export function PanelToggle({
  label,
  shown,
  onToggle,
  className,
  icon = "view.list",
  pressedLook,
}: {
  label: string;
  shown: boolean;
  onToggle: () => void;
  /// The owner's own class, which automation and captures click it by.
  className?: string;
  /// Gallery-only alternatives keep the design choice visible without changing the shipped default.
  icon?: string;
  /// Gallery-only: how the pressed toggle looks (header.css); the app ships the soft fill.
  pressedLook?: "ink" | "accent" | "dot";
}) {
  return (
    <button
      type="button"
      className={`acpmux-header-tool acpmux-header-panel-toggle${className ? ` ${className}` : ""}`}
      aria-label={label}
      aria-pressed={shown}
      data-pressed-look={pressedLook}
      {...tooltipProps(label, undefined)}
      onClick={onToggle}
    >
      <Icon name={icon} size={HEADER_GLYPH} selected={shown} />
    </button>
  );
}
