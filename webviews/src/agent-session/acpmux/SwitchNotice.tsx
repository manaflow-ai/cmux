import { useT } from "./i18n";
import { type MachineShareProps, useMachineShare } from "./MachineShareAction";
import type { AcpmuxSnapshot } from "./model";
import { type StartRefusalAction, startRefusalAction } from "./startRefusal";

/// A harness switch's line above the composer (harnessSwitch.ts). Starting draws nothing here:
/// a prompt queued behind it says "Starting Codex…" on itself, and the composer stays usable.
/// Failed says why, with Retry; the prompts it held are back in the composer. Deferred says the
/// pick waits for the next prompt while the current reply keeps streaming. A refusal with a way out
/// (startRefusal.ts) offers it in one click beside Retry: New Cloud Machine, or Choose Folder. A
/// teammate's machine also offers Share with Me, then Ask the Owner (MachineShareAction.tsx).
export function SwitchNotice({
  switching,
  onRetry,
  onShared,
  onAction,
  share,
}: {
  switching: AcpmuxSnapshot["switching"];
  onRetry(): void;
  /// Share with Me went through: start again and resend the prompt the refusal handed back.
  onShared?(): void;
  onAction?(action: StartRefusalAction): void;
  share?: MachineShareProps;
}) {
  const t = useT();
  const machineShare = useMachineShare(share, switching?.phase === "failed" ? switching : undefined, onRetry, onShared);
  if (!switching || switching.phase === "starting") return null;
  if (switching.phase === "deferred")
    return <output className="acpmux-switch-notice">{t("switch.deferred", { agent: switching.name })}</output>;
  const action = startRefusalAction(switching.code);
  return (
    <div className="acpmux-host-error acpmux-switch-failed" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">
          {t("switch.failed", { agent: switching.name, reason: switching.error ?? t("switch.unknownError") })}
        </p>
        {machineShare.line && <p className="acpmux-host-error-hint">{machineShare.line}</p>}
        <div className="acpmux-host-error-actions">
          {machineShare.button}
          {action && onAction && (
            <button
              type="button"
              data-secondary={machineShare.button ? "" : undefined}
              onClick={() => onAction(action)}
            >
              {t(action === "newCloudMachine" ? "switch.action.newCloudMachine" : "switch.action.chooseFolder")}
            </button>
          )}
          <button
            type="button"
            data-secondary={action && onAction ? "" : undefined}
            onClick={machineShare.retry ?? onRetry}
          >
            {t("switch.retry")}
          </button>
        </div>
      </div>
    </div>
  );
}
