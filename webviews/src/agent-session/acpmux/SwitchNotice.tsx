import { useT } from "./i18n";
import { type MachineShareProps, useMachineShare } from "./MachineShareAction";
import type { AcpmuxSnapshot } from "./model";
import { ErrorDetails } from "./conversation/ErrorDetails";
import { startFailureView } from "./startFailure";
import { type StartRefusalAction, startRefusalAction } from "./startRefusal";

/// What the card's one-click way out asks for: a refusal's own (startRefusal.ts), or Install for an
/// agent that is not on the machine (startFailure.ts).
export type SwitchNoticeAction = StartRefusalAction | "install";

/// A harness switch's line above the composer (harnessSwitch.ts). Starting draws nothing here:
/// a prompt held behind it reads as sent with Thinking under it, and the composer stays usable,
/// its Stop taking the prompt back (Leo, 2026-11-01).
/// Failed says why, with Retry; the prompts it held are back in the composer. Deferred says the
/// pick waits for the next prompt while the current reply keeps streaming. A refusal with a way out
/// (startRefusal.ts) offers it in one click beside Retry: New Cloud Machine, or Choose Folder. A
/// teammate's machine also offers Share with Me, then Ask the Owner (MachineShareAction.tsx).
/// The sentence is always plain words (startFailure.ts): an agent that is not installed says so and
/// offers Install, other failures read as a failed turn's do, and the agent's raw words wait under
/// Details with Copy error.
export function SwitchNotice({
  switching,
  onRetry,
  onShared,
  onAction,
  share,
  installs = true,
}: {
  switching: AcpmuxSnapshot["switching"];
  onRetry(): void;
  /// Share with Me went through: start again and resend the prompt the refusal handed back.
  onShared?(): void;
  onAction?(action: SwitchNoticeAction): void;
  share?: MachineShareProps;
  /// Whether Install may be offered: the installer runs in a terminal tab of this Mac, so a chat on
  /// another machine never offers it (its sentence still says the agent is not installed there).
  installs?: boolean;
}) {
  const t = useT();
  const machineShare = useMachineShare(share, switching?.phase === "failed" ? switching : undefined, onRetry, onShared);
  if (!switching || switching.phase === "starting") return null;
  if (switching.phase === "deferred")
    return <output className="acpmux-switch-notice">{t("switch.deferred", { agent: switching.name })}</output>;
  const view = startFailureView(t, switching);
  const action: SwitchNoticeAction | undefined =
    startRefusalAction(switching.code) ?? (installs && view.install ? "install" : undefined);
  return (
    <div className="acpmux-host-error acpmux-switch-failed" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">{view.sentence}</p>
        {machineShare.line && <p className="acpmux-host-error-hint">{machineShare.line}</p>}
        <div className="acpmux-host-error-actions">
          {machineShare.button}
          {action && onAction && (
            <button
              type="button"
              data-secondary={machineShare.button ? "" : undefined}
              onClick={() => onAction(action)}
            >
              {t(
                action === "install"
                  ? "switch.action.install"
                  : action === "newCloudMachine"
                    ? "switch.action.newCloudMachine"
                    : "switch.action.chooseFolder",
              )}
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
        {view.detail && <ErrorDetails text={view.detail} className="acpmux-host-error-details" />}
      </div>
    </div>
  );
}
