import { type ReactNode, useId, useState } from "react";
import { Notice } from "../../ui/Notice";
import { HOST_ERROR_DEADLINE_MS, type HostRestoring, hostRecoveryLine } from "./hostRetry";
import { useNow } from "./subagents/subagentGroupModel";
import { useT } from "./i18n";
import { waitedText } from "./hostErrorModel";

/// A chat acpmux would not start (a folder harness without its Enable or Trust): the reason above
/// the composer as the shared notice (ui/Notice.tsx), with its own `hint` (null: none) and button
/// (`action`, the label for `onRetry`); without `onRetry` it has no button. With its own action it is
/// a warning that waits for that step; with plain Retry it is an error whose Retry leads.
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
  const label = action ?? t(retrying ? "host.retryQueued" : "host.retry");
  return (
    <div className="acpmux-host-error">
      <Notice
        kind={action ? "warning" : "error"}
        title={hint ? message : undefined}
        message={hint ?? message}
        retry={!action && onRetry ? { label, onRetry, disabled: retrying } : undefined}
        actions={
          action && onRetry ? [{ id: "action", label, onSelect: onRetry, disabled: retrying, primary: true }] : []
        }
      />
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
///
/// Under it, one muted line answers what the person wonders first (Leo, 2026-11-06: "has my app
/// completely crashed? Should I be restarting it?"): cmux is running and the chats are kept, and,
/// while the pane asks again by itself (`selfRetrying`, every failure but one asking again cannot
/// change), that it keeps retrying. The waiting line has the same two rows at the same heights, so
/// one turning into the other moves nothing.
export function HostUnavailableLine({
  message,
  detail,
  retrying,
  onRetry,
  restarting,
  onRestart,
  selfRetrying = true,
}: {
  message: string;
  detail?: string;
  retrying?: boolean;
  onRetry?(): void;
  restarting?: boolean;
  onRestart?(): void;
  selfRetrying?: boolean;
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
      <HostReassurance selfRetrying={selfRetrying} />
      {detail && open && (
        <p id={detailId} className="acpmux-host-line-detail selectable">
          {detail}
        </p>
      )}
    </div>
  );
}

/// The host line's second row: cmux is running and the chats are kept, and whether the pane keeps
/// asking by itself. It holds no button in either line, so its height is its text's in both, and
/// the waiting line turning into the failure line moves nothing.
function HostReassurance({ selfRetrying }: { selfRetrying: boolean }) {
  const t = useT();
  return (
    <div className="acpmux-host-line acpmux-host-line-reassure">
      <p className="acpmux-host-line-note">{t(selfRetrying ? "host.keptRetrying" : "host.kept")}</p>
    </div>
  );
}

/// The pane's handshake waits for this app's acpmux, which has not answered yet. The app never
/// restarts a slow acpmux on its own (rule R5: a late answer is not a crash, and under load a
/// restart reloads every chat), so the person sees how long the pane has waited, that cmux is
/// running, the chats are kept and the pane keeps asking, and may decide: Restart agent service, a
/// quiet text button after the time (optional, never a filled button), stops that daemon (its
/// chats are kept) and the pane asks again, which starts a new one. Nothing shows while a wait is short (`HOST_ERROR_DEADLINE_MS`, the pane's
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
    <output className="acpmux-host-line-group" data-host-waiting>
      <div className="acpmux-host-line">
        <p className="acpmux-host-line-message">{t("host.waitingService", { time: waitedText(waited) })}</p>
        {onRestart && (
          <button type="button" className="acpmux-host-line-quiet" onClick={onRestart} disabled={restarting}>
            {t(restarting ? "host.restartingService" : "host.restartService")}
          </button>
        )}
      </div>
      <HostReassurance selfRetrying />
    </output>
  );
}

/// The quiet line while the pane gets its chat back on its own (hostRetry.ts `hostRecoveryLine`):
/// "Restoring sessions… m:ss" while the host says acpmux restores its chats, "Reconnecting…" while
/// a lost connection comes back. No button and no card: nothing waits on the person. Otherwise
/// (`otherwise`) the host's other line, if any.
export function HostRecoveringLine({
  relinkingSince,
  restoring,
  otherwise = null,
  now: fixedNow,
}: {
  relinkingSince?: number;
  restoring?: HostRestoring;
  otherwise?: ReactNode;
  /// A fixed clock for the gallery and tests; the pane passes none and the line counts each second.
  now?: number;
}) {
  const t = useT();
  const ticking = useNow(fixedNow === undefined && (relinkingSince !== undefined || restoring !== undefined));
  const line = hostRecoveryLine({ relinkingSince, restoring, now: fixedNow ?? ticking });
  if (!line) return otherwise;
  return (
    <output className="acpmux-host-line" data-host-recovering={line.kind}>
      <p className="acpmux-host-line-message">
        {line.kind === "restoring"
          ? t("host.restoringSessions", { time: waitedText(line.waitedMs) })
          : t("host.reconnecting")}
      </p>
    </output>
  );
}
