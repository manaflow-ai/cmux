// One Inspector section: its title with a disclosure triangle and a one-line value on the right
// (a count, a percent), folding its body. Without `onOpenChange` the head is plain text (Context
// before the agent reports usage). With `icon`, the head starts with it, so a section that is one
// line lines up with the rows above it (the rail's top block, ChatInspector.tsx `RAIL_LAYOUT`).
// `bare` draws the body alone, with no head: rows that need no title over them.
import type { ReactNode } from "react";
import { Disclosure } from "../../../ui/Disclosure";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";

const ROW_ICON = rowIconSize(12);

/// The shared whole-row fold used by every expandable list in Session Info. Keeping the button
/// here makes its keyboard semantics and visual contract available to new sections (Sources, etc.).
export function InspectorFold({
  open,
  onToggle,
  className,
  children,
}: {
  open: boolean;
  onToggle: () => void;
  className?: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      className={["acpmux-chat-inspector-fold", className].filter(Boolean).join(" ")}
      aria-expanded={open}
      onClick={onToggle}
    >
      {children}
    </button>
  );
}

export function InspectorSection({
  id,
  title,
  open,
  onOpenChange,
  meta,
  icon,
  bare = false,
  children,
}: {
  id: string;
  title: string;
  open: boolean;
  onOpenChange?: (open: boolean) => void;
  meta?: ReactNode;
  icon?: string;
  bare?: boolean;
  children?: ReactNode;
}) {
  const head = (foldable: boolean) => (
    <>
      {icon && <Icon name={icon} size={ROW_ICON} row className="acpmux-chat-inspector-section__icon" />}
      <span className="acpmux-chat-inspector-section__title">{title}</span>
      {foldable && (
        <Icon
          name={open ? "disclosure.expanded" : "disclosure.collapsed"}
          size={10}
          className="acpmux-chat-inspector-section__fold"
        />
      )}
      {meta && <span className="acpmux-chat-inspector-section__meta">{meta}</span>}
    </>
  );
  return (
    <section
      className="acpmux-chat-inspector-section"
      data-section={id}
      data-bare={bare || undefined}
      aria-label={title}
    >
      {bare ? (
        children
      ) : onOpenChange ? (
        <Disclosure
          label={head(true)}
          open={open}
          onOpenChange={onOpenChange}
          className="acpmux-chat-inspector-section__disclosure"
        >
          {children}
        </Disclosure>
      ) : (
        <div className="acpmux-chat-inspector-section__head">{head(false)}</div>
      )}
    </section>
  );
}
