import { type ReactNode, useId, useState } from "react";
import { Notice } from "../../ui/Notice";
import { Clock } from "../../ui/Typography";
import { type HostRestoring, hostRecoveryLine } from "./hostRetry";
import { useNow } from "./subagents/subagentGroupModel";
import { useT } from "./i18n";
import { waitedText } from "./hostErrorModel";
import { useDotSaysRecovery } from "./composerStatusStore";
import { Icon } from "./icons/Icon";
import "./conversation/cardFit.css";

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
/// While the pane asks again by itself (`selfRetrying`: every failure but one asking again cannot
/// change, such as a machine that is rebooting or an agent service that is starting), the line is
/// only "Reconnecting…": no Retry, no Details, no reassurance under it, since nothing waits on the
/// person and the chat comes back by itself (Leo, 2026-11-12: "the recovery needs to be a lot better
/// and it shouldn't talk so much bullshit"; "try what? no, it should just automatically do stuff").
/// Only a failure asking again cannot clear keeps its message and its one action.
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
  if (selfRetrying && !onRestart) return <ReconnectingLine />;
  const restartLabel = t(restarting ? "host.restarting" : "host.restart");
  const retryLabel = t(retrying ? "host.retryQueued" : "host.retry");
  // Its own width decides the layout (cardFit.css): a narrow pane puts the buttons under the reason,
  // and a narrower one shows Restart and Retry as their icons.
  return (
    <div className="acpmux-host-line-group cv-fit" role="alert">
      <div className="acpmux-host-line cv-fit-row">
        <p
          className="acpmux-host-line-message cv-fit-text selectable"
          // tooltip-allow: a long reason is cut to the line; its whole text is the tooltip
          title={message}
        >
          {message}
        </p>
        <span className="acpmux-host-line-actions cv-fit-actions">
          {onRestart ? (
            // A queued Retry holds Restart acpmux until its handshake settles (#27646).
            <button
              type="button"
              title={restartLabel}
              aria-label={restartLabel}
              onClick={onRestart}
              disabled={restarting || retrying}
            >
              <Icon name="action.restart" size={12} />
              <span className="cv-fit-label">{restartLabel}</span>
            </button>
          ) : (
            onRetry && (
              <button type="button" title={retryLabel} aria-label={retryLabel} onClick={onRetry} disabled={retrying}>
                <Icon name="action.retry" size={12} />
                <span className="cv-fit-label">{retryLabel}</span>
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
        </span>
      </div>
      {detail && open && (
        <p id={detailId} className="acpmux-host-line-detail selectable">
          {detail}
        </p>
      )}
    </div>
  );
}

/// The pane's link state as a small chip, never a row. Leo, 2026-11-21, on the phone's "reconnecting
/// to..." messages: "these messages should not be pushing up the text... typically for these connection
/// indicstors you can just put a small unobtrusive thing somewhere without needing to block any
/// content ... toast type thing somewhere at top middle or left or right as a symbol or short thing,
/// not a sentence. stop layout shifting"; and "where did I say this is only iOS?": the rule is the
/// desktop's and the web's too. So the chip is drawn out of flow: HostLineSlot is a zero-height box in
/// the dock, and the chip floats over the transcript's last pixels above the composer, so it appears
/// and goes without moving one row (noLayoutShift.ts is the test). It shows only while the
/// connection is down for real, as the transport says (hostRetry.ts `hostRecoveryLine`), never after a clock.
///
/// `variant` is for the gallery: `chip` (shipped) is a dot and one word beside the composer's top edge,
/// `dot` only the dot (its words are the tooltip and the label), `corner` the chip in the pane's top
/// end corner.
export type ConnectionChipVariant = "chip" | "dot" | "corner";

export function ConnectionChip({
  kind,
  words,
  variant = "chip",
}: {
  kind: "reconnecting" | "restoring";
  /// The chip's words: the line's own, which a dot keeps as its label and tooltip.
  words: ReactNode;
  variant?: ConnectionChipVariant;
}) {
  const label = typeof words === "string" ? words : undefined;
  return (
    <output
      className="acpmux-host-chip"
      data-host-recovering={kind}
      data-chip={variant}
      aria-label={variant === "dot" ? label : undefined}
      // tooltip-allow: the dot's only words
      title={variant === "dot" ? label : undefined}
    >
      <span className="acpmux-host-chip-dot" aria-hidden="true" />
      {variant !== "dot" && <span className="acpmux-host-chip-words">{words}</span>}
    </output>
  );
}

/// Where the pane's host line lives: a zero-height box above the composer that is in the dock in every
/// state, so what it holds (a chip, a Restart acpmux or Retry line) is positioned over the transcript's
/// end instead of taking a row of its own and pushing the messages up (styles.css `.acpmux-host-slot`).
export function HostLineSlot({ children }: { children?: ReactNode }) {
  return (
    <div className="acpmux-host-slot" data-host-slot>
      {children}
    </div>
  );
}

/// The one quiet chip while the pane gets its agent back by itself: "Reconnecting…", the same chip
/// HostRecoveringLine shows for a short reconnect, so a long one changes nothing on screen.
function ReconnectingLine({ variant }: { variant?: ConnectionChipVariant }) {
  const t = useT();
  return <ConnectionChip kind="reconnecting" words={t("host.reconnecting")} variant={variant} />;
}

/// The quiet line while the pane gets its chat back on its own (hostRetry.ts `hostRecoveryLine`):
/// "Restoring sessions… m:ss" while the host says acpmux restores its chats, "Reconnecting…" while
/// a lost connection comes back, as a ConnectionChip (out of flow). No button and no card: nothing
/// waits on the person. Otherwise
/// (`otherwise`) the host's other line, if any.
export function HostRecoveringLine({
  linkDown,
  restoring,
  failureShown,
  otherwise = null,
  now: fixedNow,
  variant,
}: {
  /// The chip's look, for the gallery; the pane passes none.
  variant?: ConnectionChipVariant;
  /// An attempt to connect failed for real and none connected since (App.tsx `linkDown`).
  linkDown?: boolean;
  restoring?: HostRestoring;
  /// The pane already says a failure (`hostErrorSaid`): "Reconnecting…" leaves the line to it.
  failureShown?: boolean;
  otherwise?: ReactNode;
  /// A fixed clock for the gallery and tests; the pane passes none and the restore's time counts each second.
  now?: number;
}) {
  const t = useT();
  // The composer's status dot, once mounted, says this recovery instead (ComposerStatusDot.tsx), so
  // the words never draw over the transcript (Leo, 2026-11-22); the line still yields to `otherwise`.
  const dotSays = useDotSaysRecovery();
  // Only the restore's m:ss needs the clock; "Reconnecting…" is state, not time.
  const ticking = useNow(fixedNow === undefined && !dotSays && linkDown === true && restoring !== undefined);
  const line = hostRecoveryLine({ linkDown, restoring, failureShown, now: fixedNow ?? ticking });
  if (!line || dotSays) return otherwise;
  return line.kind === "restoring" ? (
    <ConnectionChip
      kind="restoring"
      variant={variant}
      words={<ClockedWords text={t("host.restoringSessions", { time: SLOT })} time={waitedText(line.waitedMs)} />}
    />
  ) : (
    <ReconnectingLine variant={variant} />
  );
}

/// The translation's time slot, filled with the ticking time.
const SLOT = "\u0000";

/// A line's words with its ticking `m:ss` in the shared clock (ui/Typography.tsx `Clock`): tabular
/// figures in a box as wide as the widest time of its shape, so a tick never moves what follows the
/// time (proportional figures would jiggle the line each second). `text` is the
/// translation with `SLOT` where the time goes.
function ClockedWords({ text, time }: { text: string; time: string }) {
  const [before, after = ""] = text.split(SLOT);
  return (
    <>
      {before}
      <Clock text={time} />
      {after}
    </>
  );
}
