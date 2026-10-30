import { useT } from "./i18n";

/// A chat acpmux would not start (a folder harness without its Enable or Trust): the reason above
/// the composer in a card, with its own `hint` (null: none) and button (`action`, the label for
/// `onRetry`); without `onRetry` it has no button.
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
  return (
    <div className="acpmux-host-error" role="alert">
      <div className="acpmux-host-error-card">
        <p className="acpmux-host-error-message selectable">{message}</p>
        {hint && <p className="acpmux-host-error-hint">{hint}</p>}
        {onRetry && (
          <div className="acpmux-host-error-actions">
            <button type="button" onClick={onRetry} disabled={retrying}>
              {action ?? t(retrying ? "host.retryQueued" : "host.retry")}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

/// Why the host could not hand the pane acpmux, once that is a failure (hostRetry.ts
/// `hostErrorShows`: a refusal at once, a recovery only past its deadline). One line in the host's
/// words with one small action, and no recovery steps: the pane keeps retrying on its own and the
/// prompt stays in the composer (Leo, 2026-10-29: "GOD THESE FUCKING RECOVERY STEPS ARE SO FUCKING
/// RETARDED"). The action is Restart acpmux when another binary's daemon holds this app's socket
/// (`onRestart`, in flight while `restarting`), else Retry, which asks again now (`retrying` while
/// it waits on the attempt in flight).
export function HostUnavailableLine({
  message,
  retrying,
  onRetry,
  restarting,
  onRestart,
}: {
  message: string;
  retrying?: boolean;
  onRetry?(): void;
  restarting?: boolean;
  onRestart?(): void;
}) {
  const t = useT();
  return (
    <div className="acpmux-host-line" role="alert">
      <p
        className="acpmux-host-line-message selectable"
        // tooltip-allow: a long reason is cut to the line; its whole text is the tooltip
        title={message}
      >
        {message}
      </p>
      {onRestart ? (
        // A queued Retry holds Restart acpmux until its handshake settles (#27646).
        <button type="button" onClick={onRestart} disabled={restarting || retrying}>
          {t(restarting ? "host.restarting" : "host.restart")}
        </button>
      ) : (
        onRetry && (
          <button type="button" onClick={onRetry} disabled={retrying}>
            {t(retrying ? "host.retryQueued" : "host.retry")}
          </button>
        )
      )}
    </div>
  );
}
