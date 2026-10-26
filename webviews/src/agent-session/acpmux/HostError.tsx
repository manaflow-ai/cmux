import { useT } from "./i18n";

/// Why the host could not hand the pane acpmux, in the host's words (which carry the next
/// step, such as where to install it), above the composer. The pane keeps retrying on its own;
/// Retry asks again now, or once the attempt in flight ends (`retrying`). A chat acpmux would not
/// start (a folder harness without its Enable) uses the same card with its own `hint` (null: none)
/// and button (`action`, the label for `onRetry`); without `onRetry` it has no button.
export function HostError({
  message,
  retrying,
  onRetry,
  hint,
  action,
  restarting,
  onRestart,
}: {
  message: string;
  retrying?: boolean;
  onRetry?(): void;
  hint?: string | null;
  action?: string;
  restarting?: boolean;
  onRestart?(): void;
}) {
  const t = useT();
  const shownHint = hint === undefined ? t(onRestart ? "host.restartHint" : "host.retrying") : hint;
  return (
    <div className="acpmux-host-error" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message selectable">{message}</p>
        {shownHint && <p className="acpmux-host-error-hint">{shownHint}</p>}
        {(onRestart || onRetry) && (
          <div className="acpmux-host-error-actions">
            {onRestart && (
              <button type="button" onClick={onRestart} disabled={restarting}>
                {t(restarting ? "host.restarting" : "host.restart")}
              </button>
            )}
            {onRetry && (
              <button type="button" onClick={onRetry} disabled={retrying || restarting} data-secondary={onRestart ? "" : undefined}>
                {action ?? t(retrying ? "host.retryQueued" : "host.retry")}
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
