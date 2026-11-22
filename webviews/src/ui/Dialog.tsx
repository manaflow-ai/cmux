// A modal dialog over Base UI Dialog: focus moves in and is trapped, the page behind is inert,
// Escape and a press outside dismiss it, and focus returns to where it was.
import { useEffect, type ReactNode } from "react";
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
  /** Keys of the dialog's own content. The popup takes focus when a press inside lands on no
   * focusable element, so a handler on an inner element would miss them. */
  onKeyDown?: (event: React.KeyboardEvent<HTMLElement>) => void;
  children: ReactNode;
}

export function Dialog({
  open,
  onOpenChange,
  label,
  className,
  backdropClassName,
  initialFocus,
  onKeyDown,
  children,
}: DialogProps) {
  const container = usePortalContainer();
  useEffect(() => {
    if (!open) return;
    const guardChordEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || !(event.metaKey || event.ctrlKey || event.altKey)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    };
    document.addEventListener("keydown", guardChordEscape, true);
    return () => document.removeEventListener("keydown", guardChordEscape, true);
  }, [open]);
  return (
    <BaseDialog.Root open={open} onOpenChange={(next) => onOpenChange(next)}>
      <BaseDialog.Portal container={container}>
        <BaseDialog.Backdrop className={cx("ui-backdrop", backdropClassName)} />
        <BaseDialog.Popup
          className={cx("ui-dialog", className)}
          aria-label={label}
          initialFocus={initialFocus}
          onKeyDown={onKeyDown}
          onKeyDownCapture={(event) => {
            // Cmd/Ctrl/Option chords belong to the host dispatcher, even while a dialog is open.
            if (event.key === "Escape" && (event.metaKey || event.ctrlKey || event.altKey)) {
              event.preventDefault();
              event.stopPropagation();
            }
          }}
        >
          {children}
        </BaseDialog.Popup>
      </BaseDialog.Portal>
    </BaseDialog.Root>
  );
}
