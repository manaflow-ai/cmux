// The hover preview of `animated-morph` (headerMotion.ts): resting on a top-right icon shows what a
// click opens before it happens: a small drawing of the pane with the chat on the left and the panel
// where it lands (the right column, or under the chat for Split Down), its tab lit with the icon's
// glyph, then the button's name, its key and what it holds (Browser's page address). An icon whose
// panel is open draws that panel dashed: the click closes it. It stands in for the tooltip, so the
// two never stack. No new strings: the name, key and address are the button's own.
import { useLayoutEffect, useState } from "react";
import { createPortal } from "react-dom";
import { hoverCardGlass, hoverCardUnder } from "../../../ui/glass/hoverCardGlass";
import { attachSeeThroughBlur } from "../../../ui/glass/seeThroughBlur";
import { interfaceScale } from "../../../ui/interfaceScale";
import { HeaderIcon } from "./HeaderIcon";
import { headerToolPreviewPlacement, PREVIEW_GAP } from "./headerToolPreviewPlacement";

export interface HeaderToolPreviewTarget {
  id: string;
  icon: string;
  label: string;
  title?: string;
  shortcut?: string;
  pressed?: boolean;
  /// The button's box, as the pointer came to rest.
  box: { left: number; right: number; bottom: number };
}

export function HeaderToolPreview({ target }: { target: HeaderToolPreviewTarget }) {
  // The one hover card material (ui/glass/hoverCardGlass.ts), as every hover card: the App's popover
  // glass under the page and the chat it covers blurred in place. It drew the solid elevated surface
  // before (Leo, 2026-11-20: "WHERE IS THE GLASS EVERYWHERE ALL THESE STUPID F***ING HOVER TOOLTIPS
  // AND HOVER PREVIEW SHIT").
  const [card, setCard] = useState<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    if (!card) return;
    return attachSeeThroughBlur(card, hoverCardUnder, hoverCardGlass);
  }, [card]);
  const doc = typeof document === "undefined" ? undefined : document;
  if (!doc) return null;
  // Its frame follows Text Size as its name and key do (ui/interfaceScale.ts); it shows for one
  // hover, so it reads the scale as it renders. The stylesheet bounds it to the window.
  const scale = interfaceScale(doc.defaultView);
  const { width, right } = headerToolPreviewPlacement(doc.documentElement.clientWidth, target.box.right, scale);
  const down = target.id === "splitDown";
  return createPortal(
    <div
      ref={setCard}
      className="ui-card ui-glass acpmux-header-preview"
      data-host-glass="popover"
      role="tooltip"
      data-closes={target.pressed ? "" : undefined}
      style={{ top: target.box.bottom + PREVIEW_GAP * scale, right, width }}
    >
      <div className={`acpmux-header-preview-pane${down ? " acpmux-header-preview-pane-down" : ""}`} aria-hidden="true">
        <div className="acpmux-header-preview-chat">
          <i />
          <i />
          <i />
        </div>
        <div className="acpmux-header-preview-panel">
          <span className="acpmux-header-preview-tab">
            <HeaderIcon name={target.icon} size={12} />
          </span>
        </div>
      </div>
      <div className="acpmux-header-preview-text">
        <span className="acpmux-header-preview-name">{target.label}</span>
        {target.shortcut && <kbd className="acpmux-header-preview-key">{target.shortcut}</kbd>}
      </div>
      {target.title && target.title !== target.label && (
        <div className="acpmux-header-preview-detail">{target.title}</div>
      )}
    </div>,
    doc.body,
  );
}
