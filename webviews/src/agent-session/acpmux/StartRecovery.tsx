import { useState } from "react";
import { Dialog, DialogDescription } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import { experimentArm } from "../../experiments/experiment";
import { useT } from "./i18n";
import { startRecoveryLook } from "./startRecovery.experiment";
import { useStartRecoveryPreview } from "./startRecoveryPreview";
import "../../ui/controls.css";
import "./startRecovery.css";

/** Which blocked state the dialog shows (ux-start-anyway.md first slice): an agent missing from this Mac
 * (Install) or an agent not signed in on this Mac (Sign in to <agent>, its login in a terminal tab).
 * Offline never mounts it yet; the notice's Retry stays its way out. */
export type StartRecoveryKind = "install" | "signIn";

type RecoveryProps = {
  kind: StartRecoveryKind;
  sentence: string;
  /// The primary button's words: the notice's own label for the same action.
  label: string;
  /// The notice's own operation for the same action; the dialog never runs anything else.
  onAction(): void;
};

/** Additional presentation only: the notice stays mounted and owns classification and recovery.
 * Key this by the selected failure so a dismissed old selection never hides a new refusal.
 * Only mount where the existing surface can run the action on the selected machine. */
export function StartRecovery(props: RecoveryProps) {
  const enabled = useStartRecoveryPreview();
  return enabled ? <RecoveryDialog {...props} /> : null;
}

function RecoveryDialog({ kind, sentence, label, onAction }: RecoveryProps) {
  const t = useT();
  const [open, setOpen] = useState(true);
  return (
    <Dialog
      open={open}
      onOpenChange={setOpen}
      label={label}
      className="acpmux-start-recovery ui-glass ui-glass-floats"
      backdropClassName="acpmux-start-recovery-backdrop"
    >
      <div className="acpmux-start-recovery-layout" data-layout={experimentArm(startRecoveryLook)}>
        {kind === "signIn" ? <SignInArt /> : <InstallArt />}
        <DialogDescription className="acpmux-start-recovery-reason">{sentence}</DialogDescription>
        <div className="acpmux-start-recovery-actions">
          <DialogButton
            dialogKey="escape"
            className="ui-btn"
            data-variant="subtle"
            data-size="md"
            onClick={() => setOpen(false)}
          >
            {t("worktree.dismiss")}
          </DialogButton>
          <DialogButton
            dialogKey={null}
            className="ui-btn"
            data-variant="solid"
            data-size="md"
            onClick={() => {
              // No automatic setup or retry. The owning surface handles success/failure and its draft.
              setOpen(false);
              onAction();
            }}
          >
            {label}
          </DialogButton>
        </div>
      </div>
    </Dialog>
  );
}

function InstallArt() {
  return (
    <svg className="acpmux-start-recovery-art" viewBox="0 0 56 56" fill="none" aria-hidden="true" focusable="false">
      <path d="M8 18 28 8l20 10v22L28 50 8 40Z" fill="currentColor" opacity=".08" />
      <path
        d="m8 18 20 10 20-10M28 28v22M8 18 28 8l20 10v22L28 50 8 40Z"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinejoin="round"
      />
      <path
        d="M28 14v12m-5-5 5 5 5-5"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** A person with a key: signing in, drawn in the text colour as InstallArt is. */
function SignInArt() {
  return (
    <svg className="acpmux-start-recovery-art" viewBox="0 0 56 56" fill="none" aria-hidden="true" focusable="false">
      <circle cx="24" cy="18" r="8" fill="currentColor" opacity=".08" />
      <circle cx="24" cy="18" r="8" stroke="currentColor" strokeWidth="2" />
      <path d="M8 46c0-9 7-15 16-15 3 0 6 .7 8.4 2" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
      <circle cx="40" cy="40" r="5" stroke="currentColor" strokeWidth="2" />
      <path
        d="M44 36l6-6m-3 3 3 3"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
