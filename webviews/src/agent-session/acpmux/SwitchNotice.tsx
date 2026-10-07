import { useT } from "./i18n";
import type { AcpmuxSnapshot } from "./model";

/// A harness switch's line above the composer (harnessSwitch.ts). Starting draws nothing here:
/// a prompt queued behind it says "Starting Codex…" on itself, and the composer stays usable.
/// Failed says why, with Retry; the prompts it held are back in the composer. Deferred says the
/// pick waits for the next prompt while the current reply keeps streaming.
export function SwitchNotice({ switching, onRetry }: { switching: AcpmuxSnapshot["switching"]; onRetry(): void }) {
  const t = useT();
  if (!switching || switching.phase === "starting") return null;
  if (switching.phase === "deferred")
    return <output className="acpmux-switch-notice">{t("switch.deferred", { agent: switching.name })}</output>;
  return (
    <div className="acpmux-host-error acpmux-switch-failed" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">
          {t("switch.failed", { agent: switching.name, reason: switching.error ?? t("switch.unknownError") })}
        </p>
        <button type="button" onClick={onRetry}>
          {t("switch.retry")}
        </button>
      </div>
    </div>
  );
}
