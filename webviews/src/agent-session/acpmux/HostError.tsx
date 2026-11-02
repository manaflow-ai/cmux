import { type ReactNode, useId, useState } from "react";
import { DialogButton } from "../../ui/DialogButton";
import { HOST_ERROR_DEADLINE_MS } from "./hostRetry";
import { useNow } from "./subagents/SubagentGroup";
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
/// `hostErrorShows`: a refusal at once, a recovery only past its deadline, a chat's machine that is
/// not reachable only once it is really gone). One plain line, never red, with one small action and
/// no recovery steps: the pane keeps retrying on its own and the prompt stays in the composer (Leo,
/// 2026-10-29: "GOD THESE FUCKING RECOVERY STEPS ARE SO FUCKING RETARDED"). acpmux's own words (a
/// code, link state, a command to run) are never the line: they are `detail`, shown only when the
/// person opens Details (hostLine.ts, Leo 2026-10-30: "that's not the fucking right time to be
/// showing that kind of fucking message"). The action is Restart acpmux when another binary's daemon
/// holds this app's socket (`onRestart`, in flight while `restarting`), else Retry, which asks again
/// now (`retrying` while it waits on the attempt in flight).
export function HostUnavailableLine({
  message,
  detail,
  retrying,
  onRetry,
  restarting,
  onRestart,
}: {
  message: string;
  detail?: string;
  retrying?: boolean;
  onRetry?(): void;
  restarting?: boolean;
  onRestart?(): void;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const detailId = useId();
  return (
    <div className="acpmux-host-line-group" role="alert">
      <div className="acpmux-host-line">
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
        {detail && (
          <button
            type="button"
            className="acpmux-host-line-details"
            aria-expanded={open}
            aria-controls={detailId}
            onClick={() => setOpen((was) => !was)}
          >
            {t("host.details")}
          </button>
        )}
      </div>
      {detail && open && (
        <p id={detailId} className="acpmux-host-line-detail selectable">
          {detail}
        </p>
      )}
    </div>
  );
}

/// How long the pane has waited, as `m:ss` (a count, the same in every language).
export function waitedText(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/// The pane's handshake waits for this app's acpmux, which has not answered yet. The app never
/// restarts a slow acpmux on its own (rule R5: a late answer is not a crash, and under load a
/// restart reloads every chat), so the person sees how long the pane has waited and decides:
/// Restart agent service stops that daemon (its chats are kept) and the pane asks again, which
/// starts a new one. Nothing shows while a wait is short (`HOST_ERROR_DEADLINE_MS`, the pane's
/// one rule for saying a recovery: "STOP SHOWING BULLSHIT ON LOAD"); that only decides what is
/// drawn, never whether acpmux is restarted. `since`: when the wait began (`Date.now()` time).
/// One host line shows at a time and the newest state wins: until this line shows, `otherwise`
/// (the line of an earlier failed handshake) stays; once it shows, it replaces that line.
export function HostWaitingLine({
  since,
  restarting,
  onRestart,
  otherwise = null,
  now: fixedNow,
}: {
  since: number;
  restarting?: boolean;
  /// Restart agent service; none when the host cannot restart what this wait waits on.
  onRestart?(): void;
  otherwise?: ReactNode;
  /// A fixed clock for the gallery; the pane passes none and the line counts each second.
  now?: number;
}) {
  const t = useT();
  const ticking = useNow(fixedNow === undefined);
  const waited = (fixedNow ?? ticking) - since;
  if (waited < HOST_ERROR_DEADLINE_MS && !restarting) return otherwise;
  return (
    <output className="acpmux-host-line" data-host-waiting>
      <p className="acpmux-host-line-message">{t("host.waitingService", { time: waitedText(waited) })}</p>
      {onRestart && (
        <DialogButton dialogKey={null} onClick={onRestart} disabled={restarting}>
          {t(restarting ? "host.restartingService" : "host.restartService")}
        </DialogButton>
      )}
    </output>
  );
}
