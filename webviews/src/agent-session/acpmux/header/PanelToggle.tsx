// The header's right-side panel toggle: the first of its icons, as Claude and ChatGPT desktop's is.
// One glyph whoever owns the panel (the summary, summary/SummaryButton.tsx; Session Info,
// session-info/SessionInfo.tsx). The open panel reads as pressed through its ink and selected glyph,
// keeping the same quiet surface as the other header controls (header.css). The glyph is the pack's two-row list,
// centred on the icon grid (Leo 2026-11-04: "make our session info button 2 rows too"); SF Symbols has no two-row
// list.bullet, so it has no HEADER_SYMBOLS entry and draws from the cmux pack in the app too.
import { HeaderIcon } from "./HeaderIcon";
import { HEADER_GLYPH } from "./ChatHeaderTools";
import { tooltipProps } from "../shortcuts";

export function PanelToggle({
  label,
  shown,
  onToggle,
  className,
  icon = "view.list.short",
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
      <HeaderIcon name={icon} size={HEADER_GLYPH} selected={shown} />
    </button>
  );
}
