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
}: {
  message: string;
  retrying?: boolean;
  onRetry?(): void;
  hint?: string | null;
  action?: string;
}) {
  const t = useT();
  const shownHint = hint === undefined ? t("host.retrying") : hint;
  return (
    <div className="acpmux-host-error" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message selectable">{message}</p>
        {shownHint && <p className="acpmux-host-error-hint">{shownHint}</p>}
        {onRetry && (
          <button type="button" onClick={onRetry} disabled={retrying}>
            {action ?? t(retrying ? "host.retryQueued" : "host.retry")}
          </button>
        )}
      </div>
    </div>
  );
}
