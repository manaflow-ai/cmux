import type { CSSProperties, ReactNode } from "react";
import { IconCheck, IconChevronRight } from "./icons";
import { Popover } from "./Popover";

export type MenuEntry =
  | { type: "separator" }
  | {
      /** Muted, non-interactive title row (e.g. "Logged in with API key"). */
      type: "header";
      label: ReactNode;
      icon?: ReactNode;
      /** Right-aligned node, e.g. an underlined "Learn more" link. */
      trailing?: ReactNode;
    }
  | {
      type?: "item";
      label: ReactNode;
      icon?: ReactNode;
      /** Second line under the label. */
      description?: ReactNode;
      /** Right-aligned shortcut text, e.g. "⌘,". */
      shortcut?: ReactNode;
      checked?: boolean;
      /** Show a submenu chevron. */
      submenu?: boolean;
      /** Highlighted (hovered / keyboard focus) row. */
      active?: boolean;
      disabled?: boolean;
      /** "warning" renders orange (Full access), "danger" red. */
      tone?: "default" | "warning" | "danger";
      /** Arbitrary right-side content. */
      trailing?: ReactNode;
      onClick?: () => void;
    };

export type MenuProps = {
  items: MenuEntry[];
  width?: number;
  /** Extra styles. Without `anchor`, the position in the parent's coordinates. */
  style?: CSSProperties;
  className?: string;
  /**
   * Anchor name of the control that opened it: the menu is a top-layer Popover placed by
   * `className` with anchor() insets (popover.css fallbacks keep it in the viewport).
   */
  anchor?: string;
  /** With `anchor`: light dismiss (outside click, Escape) reports here. */
  onDismiss?: () => void;
};

/** Dark rounded popover menu used for profile, model, permission and sidebar menus. */
export function Menu({ items, width, style, className = "", anchor, onDismiss }: MenuProps) {
  const rows = items.map((it, i) => {
    if (it.type === "separator") return <hr key={i} className="cx-menu__sep" />;
    if (it.type === "header")
      return (
        <div key={i} className="cx-menu__header">
          {it.icon && <span className="cx-menu__icon">{it.icon}</span>}
          <span className="cx-menu__label">{it.label}</span>
          {it.trailing && <span className="cx-menu__trailing">{it.trailing}</span>}
        </div>
      );
    const cls = [
      "cx-menu__item",
      it.active && "is-active",
      it.disabled && "is-disabled",
      it.description && "has-description",
      it.tone && it.tone !== "default" && `is-${it.tone}`,
    ]
      .filter(Boolean)
      .join(" ");
    return (
      <button type="button" key={i} role="menuitem" className={cls} onClick={it.onClick}>
        {it.icon && <span className="cx-menu__icon">{it.icon}</span>}
        <span className="cx-menu__text">
          <span className="cx-menu__label">{it.label}</span>
          {it.description && <span className="cx-menu__desc">{it.description}</span>}
        </span>
        {it.trailing}
        {it.shortcut && <span className="cx-menu__shortcut">{it.shortcut}</span>}
        {it.checked && <IconCheck className="cx-menu__check" size={16} strokeWidth={1.4} />}
        {it.submenu && <IconChevronRight className="cx-menu__chevron" size={16} />}
      </button>
    );
  });
  if (anchor)
    return (
      <Popover
        anchor={anchor}
        role="menu"
        className={`cx-menu ${className}`}
        style={{ width, ...style }}
        onDismiss={onDismiss}
      >
        {rows}
      </Popover>
    );
  return (
    <div role="menu" className={`cx-menu ${className}`} style={{ width, ...style }}>
      {rows}
    </div>
  );
}

export type TooltipProps = {
  text: ReactNode;
  shortcut?: ReactNode;
  style?: CSSProperties;
  className?: string;
};

/** Small dark tooltip bubble. Position it absolutely via `style`. */
export function Tooltip({ text, shortcut, style, className = "" }: TooltipProps) {
  return (
    <div role="tooltip" className={`cx-tooltip ${className}`} style={style}>
      <span>{text}</span>
      {shortcut && <span className="cx-tooltip__shortcut">{shortcut}</span>}
    </div>
  );
}
