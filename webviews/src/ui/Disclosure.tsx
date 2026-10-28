// A disclosure over Base UI Collapsible: a button that shows and hides a region (`aria-expanded`).
import type { ReactNode } from "react";
import { Collapsible } from "@base-ui/react/collapsible";
import { cx } from "./cx";

export interface DisclosureProps {
  label: ReactNode;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?(open: boolean): void;
  className?: string;
  triggerWrapper?: (trigger: ReactNode) => ReactNode;
  children: ReactNode;
}

export function Disclosure({
  label,
  open,
  defaultOpen,
  onOpenChange,
  className,
  triggerWrapper,
  children,
}: DisclosureProps) {
  const trigger = <Collapsible.Trigger className="ui-button ui-disclosure-trigger">{label}</Collapsible.Trigger>;
  return (
    <Collapsible.Root
      className={cx("ui-disclosure", className)}
      open={open}
      defaultOpen={defaultOpen}
      onOpenChange={onOpenChange ? (next) => onOpenChange(next) : undefined}
    >
      {triggerWrapper ? triggerWrapper(trigger) : trigger}
      <Collapsible.Panel className="ui-disclosure-panel">{children}</Collapsible.Panel>
    </Collapsible.Root>
  );
}
