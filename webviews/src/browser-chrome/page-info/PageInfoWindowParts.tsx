// The parts the Page Info windows share: the window's content frame (Escape closes, Return presses
// the default button) and a row (icon column, title over subtitle, a trailing control), at
// pageInfoWindows.css's metrics.
import type { KeyboardEvent, ReactNode } from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import "./pageInfoWindows.css";

export function WindowFrame({
  look,
  label,
  onClose,
  onReturn,
  children,
  className,
}: {
  look: string;
  label: string;
  onClose: () => void;
  /** Return outside a control (the window's default button). */
  onReturn?: () => void;
  children: ReactNode;
  className?: string;
}) {
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    // A menu or list that answered the key itself keeps it.
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    } else if (event.key === "Enter" && onReturn && !(event.target as Element).closest("button, input, [role]")) {
      event.preventDefault();
      onReturn();
    }
  };
  return (
    // The native window is the dialog; this is its content. Escape anywhere in it closes the window.
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/no-noninteractive-tabindex
    <section
      className={className ? `piw ${className}` : "piw"}
      data-look={look}
      aria-label={label}
      tabIndex={-1}
      onKeyDown={onKeyDown}
      data-gallery-track
    >
      {children}
    </section>
  );
}

export function WindowRow({
  icon,
  title,
  subtitle,
  trailing,
  id,
}: {
  icon?: string;
  title: string;
  subtitle?: string;
  trailing?: ReactNode;
  id: string;
}) {
  return (
    <li className="piw-row" data-row-id={id} data-subtitle={subtitle ? true : undefined}>
      <span className="piw-row-icon">{icon && <Icon name={icon} size={16} row />}</span>
      <span className="piw-row-text">
        <span className="piw-row-title">{title}</span>
        {subtitle && <span className="piw-row-subtitle">{subtitle}</span>}
      </span>
      {trailing}
    </li>
  );
}
