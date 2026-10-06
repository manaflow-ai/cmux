// A modal dialog over Base UI Dialog: focus moves in and is trapped, the page behind is inert,
// Escape and a press outside dismiss it, and focus returns to where it was.
import type { ReactNode } from "react";
import { Dialog as BaseDialog } from "@base-ui/react/dialog";
import { usePortalContainer } from "./UiProvider";
import { cx } from "./cx";

export interface DialogProps {
  open: boolean;
  /** Called with false on Escape (when the content did not handle it) and on a press outside. */
  onOpenChange(open: boolean): void;
  label: string;
  className?: string;
  backdropClassName?: string;
  initialFocus?: React.RefObject<HTMLElement | null> | boolean;
  children: ReactNode;
}

export function Dialog({
  open,
  onOpenChange,
  label,
  className,
  backdropClassName,
  initialFocus,
  children,
}: DialogProps) {
  const container = usePortalContainer();
  return (
    <BaseDialog.Root open={open} onOpenChange={(next) => onOpenChange(next)}>
      <BaseDialog.Portal container={container}>
        <BaseDialog.Backdrop className={cx("ui-backdrop", backdropClassName)} />
        <BaseDialog.Popup className={cx("ui-dialog", className)} aria-label={label} initialFocus={initialFocus}>
          {children}
        </BaseDialog.Popup>
      </BaseDialog.Portal>
    </BaseDialog.Root>
  );
}
