// The frame of every sheet of the page (routes.ts): one dialog, one decision. The page behind dims
// (the shared popup rule); a large title and one muted sentence say what the dialog does; the
// fields follow; the actions sit bottom-right with the primary one last. ui/Dialog traps focus,
// returns it on close and closes on Escape or a press outside. Return submits from a field;
// Cmd-Return submits from a multi-line field too.
import { useRef, type FormEvent, type KeyboardEvent, type ReactNode } from "react";
import { Dialog } from "../../ui/Dialog";
import { KeyboardScope } from "../../ui/KeyboardScope";

export interface FormDialogProps {
  title: string;
  lead?: string;
  onClose(): void;
  /** Called on Return and on the primary button; not while `busy`. */
  onSubmit?(): void;
  /** The buttons, primary last. */
  actions: ReactNode;
  busy?: boolean;
  /** A wider dialog for the Chief profile (two-line fields). */
  wide?: boolean;
  children?: ReactNode;
}

export function FormDialog({ title, lead, onClose, onSubmit, actions, busy, wide, children }: FormDialogProps) {
  // The first field takes focus (else the first action): the sheet's first decision.
  const first = useRef<HTMLElement | null>(null);
  const frame = (node: HTMLFormElement | null) => {
    first.current =
      node?.querySelector<HTMLElement>("input:not([type=file]), textarea, .lg-form-actions button") ?? null;
  };
  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!busy) onSubmit?.();
  };
  const keys = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && !busy) {
      event.preventDefault();
      onSubmit?.();
    }
  };
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      label={title}
      className={`lg-form${wide ? " wide" : ""}`}
      backdropClassName="lg-scrim"
      initialFocus={first}
    >
      <form ref={frame} className="lg-form-frame" onSubmit={submit} aria-busy={busy || undefined}>
        <KeyboardScope className="lg-form-keys" handleKeyDown={keys}>
          <header className="lg-form-head">
            <h2 className="lg-form-title">{title}</h2>
            {lead && <p className="lg-form-lead">{lead}</p>}
          </header>
          {children && <div className="lg-form-body">{children}</div>}
          <footer className="lg-form-actions">{actions}</footer>
        </KeyboardScope>
      </form>
    </Dialog>
  );
}
