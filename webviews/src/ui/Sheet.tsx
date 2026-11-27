import type { ReactNode, RefObject } from "react";
import { Dialog } from "./Dialog";
import { cx } from "./cx";

/** A modal sheet built on the shared dialog primitive. */
export interface SheetProps {
  open: boolean;
  onOpenChange(open: boolean): void;
  label: string;
  side?: "top" | "bottom" | "leading" | "trailing";
  className?: string;
  backdropClassName?: string;
  initialFocus?: RefObject<HTMLElement | null> | boolean;
  children: ReactNode;
}

/** A dialog surface with a sheet-specific placement class and the same focus and Escape rules. */
export function Sheet({
  open,
  onOpenChange,
  label,
  side = "bottom",
  className,
  backdropClassName,
  initialFocus,
  children,
}: SheetProps) {
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      label={label}
      className={cx("ui-sheet", `ui-sheet-${side}`, className)}
      backdropClassName={cx("ui-sheet-backdrop", backdropClassName)}
      initialFocus={initialFocus}
    >
      {children}
    </Dialog>
  );
}
