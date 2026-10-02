import { t } from "./i18n";

/// Why the host could not hand the pane acpmux, in the host's words (which carry the next
/// step, such as where to install it), above the composer. The pane keeps retrying on its own;
/// Retry asks again now, or once the attempt in flight ends (`retrying`).
export function HostError({ message, retrying, onRetry }: { message: string; retrying?: boolean; onRetry(): void }) {
  return (
    <div className="acpmux-host-error" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message">{message}</p>
        <p className="acpmux-host-error-hint">{t("host.retrying")}</p>
        <button type="button" onClick={onRetry} disabled={retrying}>
          {t(retrying ? "host.retryQueued" : "host.retry")}
        </button>
      </div>
    </div>
  );
}
