import { useT } from "./i18n";
import type { AcpmuxSnapshot } from "./model";
import { type StartRefusalAction, startRefusalAction } from "./startRefusal";

/// A harness switch's line above the composer (harnessSwitch.ts). Starting draws nothing here:
/// a prompt queued behind it says "Starting Codex…" on itself, and the composer stays usable.
/// Failed says why, with Retry; the prompts it held are back in the composer. Deferred says the
/// pick waits for the next prompt while the current reply keeps streaming. A refusal with a way out
/// (startRefusal.ts) offers it in one click beside Retry: New Cloud Machine, or Choose Folder.
export function SwitchNotice({
  switching,
  onRetry,
  onAction,
}: {
  switching: AcpmuxSnapshot["switching"];
  onRetry(): void;
  onAction?(action: StartRefusalAction): void;
}) {
  const t = useT();
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
        {action && onAction && (
          <button type="button" onClick={() => onAction(action)}>
            {t(action === "newCloudMachine" ? "switch.action.newCloudMachine" : "switch.action.chooseFolder")}
          </button>
        )}
        <button type="button" onClick={onRetry}>
          {t("switch.retry")}
        </button>
      </div>
    </div>
  );
}
