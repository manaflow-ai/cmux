// A modal dialog over Base UI Dialog: focus moves in and is trapped, the page behind is inert,
// Escape and a press outside dismiss it, and focus returns to where it was.
//
// A visible `DialogTitle` names the dialog and a `DialogDescription` describes it: Base UI links
// them to the popup as `aria-labelledby` and `aria-describedby`, so VoiceOver reads the title and
// the sentence a person sees. `alert` makes it an alert dialog (Base UI AlertDialog): role
// `alertdialog`, and a press outside does not dismiss it, so a confirm needs an answer.
import { useEffect, type CSSProperties, type ReactNode } from "react";
import { AlertDialog as BaseAlertDialog } from "@base-ui/react/alert-dialog";
import { Dialog as BaseDialog } from "@base-ui/react/dialog";
import { usePortalContainer } from "./UiProvider";
import { cx } from "./cx";
import { dialogGlass } from "./dialogGlass.experiment";
import { useExperimentArm } from "../experiments/useExperimentArm";

export interface DialogProps {
  open: boolean;
  /** Called with false on Escape (when the content did not handle it) and on a press outside. */
  onOpenChange(open: boolean): void;
  /** The accessible name when the dialog shows no `DialogTitle`; a title inside names it instead. */
  label?: string;
  /** An alert dialog: role `alertdialog`, and a press outside never dismisses it (Escape still does). */
  alert?: boolean;
  className?: string;
  backdropClassName?: string;
  /** The popup's own style (a custom property it reads). */
  style?: CSSProperties;
  initialFocus?: React.RefObject<HTMLElement | null> | boolean;
  /** Keys of the dialog's own content. The popup takes focus when a press inside lands on no
   * focusable element, so a handler on an inner element would miss them. */
  onKeyDown?: (event: React.KeyboardEvent<HTMLElement>) => void;
  /** A glass dialog's glass is the App's sheet glass under the page (glass/hostGlass.ts, role `sheet`, the
   * native dialog card's), where the App draws it; false keeps the page's own veil and blur
   * (popupSurface.css, THE SHEET ROLE). Default the dialog-glass experiment's arm (`experiments.dialogGlass`,
   * off by default: the page's). Only a `.ui-glass` popup takes it: a dialog with no glass of its own (an
   * image viewer) asks the App for none. */
  hostGlass?: boolean;
  children: ReactNode;
}

const GLASS_CLASS = /(?:^|\s)ui-glass(?:\s|$)/;

export function Dialog({
  open,
  onOpenChange,
  label,
  alert = false,
  className,
  backdropClassName,
  style,
  initialFocus,
  onKeyDown,
  hostGlass: hostGlassOverride,
  children,
}: DialogProps) {
  const container = usePortalContainer();
  const glassArm = useExperimentArm(dialogGlass);
  // A dialog over its surface is a `floating` surface (design-system-decisions B1): the App's sheet glass
  // under the page where the App draws it (hq RFD "Native or our own web view, per surface"), else the
  // page's own veil. glass.css (HOST GLASS) drops the page's blur and veil once the App has drawn it.
  const floats = (hostGlassOverride ?? glassArm === "host") && GLASS_CLASS.test(className ?? "");
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
  const Root = alert ? BaseAlertDialog.Root : BaseDialog.Root;
  return (
    <Root open={open} onOpenChange={(next) => onOpenChange(next)}>
      <BaseDialog.Portal container={container}>
        <BaseDialog.Backdrop className={cx("ui-backdrop", backdropClassName)} />
        <BaseDialog.Popup
          className={cx("ui-dialog", className)}
          data-surface-role="sheet"
          data-host-glass={floats ? "popover" : undefined}
          data-host-glass-role={floats ? "sheet" : undefined}
          data-host-glass-cover={floats ? "" : undefined}
          aria-label={label}
          style={style}
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
    </Root>
  );
}

export interface DialogTitleProps {
  className?: string;
  children: ReactNode;
}

/** The dialog's visible heading, which names it (`aria-labelledby`). */
export function DialogTitle({ className, children }: DialogTitleProps) {
  return <BaseDialog.Title className={cx("ui-dialog-title", className)}>{children}</BaseDialog.Title>;
}

export interface DialogDescriptionProps {
  className?: string;
  children: ReactNode;
}

/** The dialog's visible sentence, which describes it (`aria-describedby`). */
export function DialogDescription({ className, children }: DialogDescriptionProps) {
  return <BaseDialog.Description className={cx("ui-dialog-description", className)}>{children}</BaseDialog.Description>;
}
