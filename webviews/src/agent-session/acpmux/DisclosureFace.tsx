// The one label + chevron pair every menu trigger, picker chip and fold draws (ui/ghost.css
// `.ui-disclosure-face`, design/chevrons.md): the words, then the registry's chevron one
// spacing step after them. The words ellipsize before the chevron is ever cut or drawn over them.
import type { ReactNode } from "react";
import { cx } from "../../ui/cx";
import { Icon } from "./icons/Icon";

/** The chevron alone, for a control that lays out its own label (it still sits --ui-disclosure-gap after it). */
export function DisclosureChevron({ className }: { className?: string }) {
  return (
    <span className={cx("ui-disclosure-chevron", className)} aria-hidden="true">
      <Icon name="disclosure.expanded" row size={12} />
    </span>
  );
}

/** A label and its chevron, one gap apart; the label ellipsizes first. */
export function DisclosureFace({
  children,
  className,
  labelClassName,
  chevronClassName,
}: {
  children: ReactNode;
  className?: string;
  labelClassName?: string;
  chevronClassName?: string;
}) {
  return (
    <span className={cx("ui-disclosure-face", className)}>
      <span className={cx("ui-disclosure-face__label", labelClassName)}>{children}</span>
      <DisclosureChevron className={chevronClassName} />
    </span>
  );
}
