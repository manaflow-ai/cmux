import { useState } from "react";
import { Dialog, DialogDescription } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import { experimentArm } from "../../experiments/experiment";
import { useT } from "./i18n";
import { startRecoveryLook } from "./startRecovery.experiment";
import { useStartRecoveryPreview } from "./startRecoveryPreview";
import "../../ui/controls.css";
import "./startRecovery.css";

/** Additional presentation only: the notice stays mounted and owns classification and recovery.
 * Key this by the selected failure so a dismissed old selection never hides a new refusal.
 * Only mount where the existing surface can install on the selected machine. */
export function StartRecovery(props: { sentence: string; onInstall(): void }) {
  const enabled = useStartRecoveryPreview();
  return enabled ? <RecoveryDialog {...props} /> : null;
}

function RecoveryDialog({ sentence, onInstall }: { sentence: string; onInstall(): void }) {
  const t = useT();
  const [open, setOpen] = useState(true);
  return (
    <Dialog
      open={open}
      onOpenChange={setOpen}
      label={t("switch.action.install")}
      className="acpmux-start-recovery ui-glass ui-glass-floats"
      backdropClassName="acpmux-start-recovery-backdrop"
    >
      <div className="acpmux-start-recovery-layout" data-layout={experimentArm(startRecoveryLook)}>
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
              onInstall();
            }}
          >
            {t("switch.action.install")}
          </DialogButton>
        </div>
      </div>
    </Dialog>
  );
}
