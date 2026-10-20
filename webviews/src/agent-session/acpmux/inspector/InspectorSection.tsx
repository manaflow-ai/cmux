// One Inspector section: its title with a disclosure triangle and a one-line value on the right
// (a count, a percent), folding its body. Without `onOpenChange` the head is plain text (Context
// before the agent reports usage).
import type { ReactNode } from "react";
import { Disclosure } from "../../../ui/Disclosure";
import { Icon } from "../icons/Icon";

export function InspectorSection({
  id,
  title,
  open,
  onOpenChange,
  meta,
  children,
}: {
  id: string;
  title: string;
  open: boolean;
  onOpenChange?: (open: boolean) => void;
  meta?: ReactNode;
  children?: ReactNode;
}) {
  const head = (foldable: boolean) => (
    <>
      <span className="acpmux-inspector-section__title">{title}</span>
      {foldable && (
        <Icon
          name={open ? "disclosure.expanded" : "disclosure.collapsed"}
          size={10}
          className="acpmux-inspector-section__fold"
        />
      )}
      {meta && <span className="acpmux-inspector-section__meta">{meta}</span>}
    </>
  );
  return (
    <section className="acpmux-inspector-section" data-section={id} aria-label={title}>
      {onOpenChange ? (
        <Disclosure
          label={head(true)}
          open={open}
          onOpenChange={onOpenChange}
          className="acpmux-inspector-section__disclosure"
        >
          {children}
        </Disclosure>
      ) : (
        <div className="acpmux-inspector-section__head">{head(false)}</div>
      )}
    </section>
  );
}
