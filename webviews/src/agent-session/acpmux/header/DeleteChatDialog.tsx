import { useRef } from "react";
import { Dialog } from "../../../ui/Dialog";
import { DialogButton } from "../../../ui/DialogButton";

/// The title menu's Delete confirmation. It opens on its Delete button, so Return deletes as the
/// button's key hint says; Escape, an outside click and Close dismiss it (`onDismiss`).
export function DeleteChatDialog({
  open,
  onOpenChange,
  onDismiss,
  onConfirm,
  title,
  body,
  closeLabel,
}: {
  open: boolean;
  onOpenChange: (next: boolean) => void;
  onDismiss: () => void;
  onConfirm: () => void;
  title: string;
  body: string;
  closeLabel: string;
}) {
  const confirm = useRef<HTMLButtonElement | null>(null);
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      label={title}
      className="acpmux-delete-dialog"
      initialFocus={confirm}
      onKeyDown={(event) => {
        if (event.key !== "Enter" || (event.target as HTMLElement).closest("button")) return;
        event.preventDefault();
        onConfirm();
      }}
    >
      <h2>{title}</h2>
      <p>{body}</p>
      <div className="acpmux-delete-dialog-actions">
        <DialogButton dialogKey="escape" onClick={onDismiss}>
          {closeLabel}
        </DialogButton>
        <DialogButton ref={confirm} dialogKey="return" className="acpmux-delete-dialog-confirm" onClick={onConfirm}>
          {title}
        </DialogButton>
      </div>
    </Dialog>
  );
}
