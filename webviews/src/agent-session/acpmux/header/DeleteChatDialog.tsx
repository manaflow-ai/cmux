import { useRef } from "react";
import { Dialog } from "../../../ui/Dialog";
import { DialogButton } from "../../../ui/DialogButton";

/// The title menu's Delete confirmation, on the sheet role's glass (ui/popupSurface.css) with the
/// shared buttons (ui/controls.css): Close subtle, Delete the one solid danger button. It opens on its Delete button, so Return deletes as the
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
      className="ui-glass ui-glass-floats acpmux-delete-dialog"
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
        <DialogButton
          dialogKey="escape"
          className="ui-button ui-btn"
          data-variant="subtle"
          data-size="md"
          onClick={onDismiss}
        >
          {closeLabel}
        </DialogButton>
        <DialogButton
          ref={confirm}
          dialogKey="return"
          className="ui-button ui-btn"
          data-variant="solid"
          data-size="md"
          data-danger=""
          onClick={onConfirm}
        >
          {title}
        </DialogButton>
      </div>
    </Dialog>
  );
}
