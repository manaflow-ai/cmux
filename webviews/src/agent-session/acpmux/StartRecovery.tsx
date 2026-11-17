import { type ReactNode, useEffect, useRef } from "react";
import { ErrorDetails } from "./conversation/ErrorDetails";
import { Spinner } from "./conversation/icons";
import { useT } from "./i18n";
import type { StartRecoveryReason } from "./startRecoveryReason";

/// The shared view for a start that failed for a reason the person can fix in one step
/// (startRecoveryReason.ts): a theme-drawn picture of the reason, one sentence that says why, one
/// primary action and a dismissal (Leo: "really concise, actionable things, like, hey, this is
/// what you need to do for this reason"). It sits in the composer's notice slot; the message the
/// failed start handed back stays in the composer. Every step of a recovery (installing, signing
/// in, retrying) swaps the words and buttons inside this one view, so nothing around it moves.
///
/// Dismiss (or Escape inside the view) hands focus back to the composer, where the person was.
export type StartRecoveryLook = "side" | "centered" | "card";

export type StartRecoveryProps = {
  reason: StartRecoveryReason;
  /// The one sentence: why the chat did not start, in plain words.
  sentence: string;
  /// A step is running: the sentence trails a spinner and the actions wait.
  busy?: boolean;
  /// A running step's latest line (an installer's), under the sentence; never a log.
  line?: string;
  /// The raw words behind a failure, under Details with Copy error.
  detail?: string;
  /// The primary action first, then at most one more.
  actions?: ReactNode;
  onDismiss?(): void;
  /// The shipped look is `side`; the other two are the gallery's alternatives.
  look?: StartRecoveryLook;
  /// The caller's own classes and data attributes (a notice's state for its tests and styles).
  className?: string;
  data?: Record<`data-${string}`, string>;
};

export function StartRecovery({
  reason,
  sentence,
  busy = false,
  line,
  detail,
  actions,
  onDismiss,
  look = "side",
  className,
  data,
}: StartRecoveryProps) {
  const t = useT();
  // Where focus was when the view appeared: the composer, almost always. Dismiss returns it there.
  const before = useRef<Element | null>(null);
  useEffect(() => {
    before.current = document.activeElement;
  }, []);
  const dismiss = onDismiss
    ? () => {
        onDismiss();
        const back = before.current;
        if (back instanceof HTMLElement && back.isConnected) back.focus();
      }
    : undefined;
  return (
    <output
      className={`acpmux-host-error acpmux-start-recovery${className ? ` ${className}` : ""}`}
      {...data}
      data-start-recovery={reason}
      data-look={look}
      aria-busy={busy || undefined}
      onKeyDown={(event) => {
        if (event.key === "Escape" && dismiss) {
          event.stopPropagation();
          dismiss();
        }
      }}
    >
      <div className="acpmux-host-error-card acpmux-start-recovery-card">
        <RecoveryPicture reason={reason} />
        <div className="acpmux-start-recovery-body">
          {/* The spinner trails the text, so a step starting or ending never moves the words. */}
          <p className="acpmux-host-error-message">
            {sentence}
            {busy && <Spinner size={12} className="acpmux-harness-spinner" loading />}
          </p>
          {busy && line && (
            <p className="acpmux-host-error-hint acpmux-missing-harness-line" data-install-line>
              {line}
            </p>
          )}
          {(actions || dismiss) && (
            <div className="acpmux-host-error-actions">
              {actions}
              {dismiss && (
                <button type="button" data-secondary="" data-recovery-action="dismiss" onClick={dismiss}>
                  {t("picker.setup.dismiss")}
                </button>
              )}
            </div>
          )}
          {!busy && detail && <ErrorDetails text={detail} className="acpmux-host-error-details" />}
        </div>
      </div>
    </output>
  );
}

/// The reason, drawn in the theme's own colors (currentColor and the accent), so it reads in every
/// theme and in light and dark with no image assets. Decorative: the sentence says the same.
function RecoveryPicture({ reason }: { reason: StartRecoveryReason }) {
  return (
    <svg className="acpmux-start-recovery-picture" viewBox="0 0 48 48" width="48" height="48" aria-hidden="true">
      <rect x="4" y="8" width="40" height="30" rx="6" className="acpmux-start-recovery-frame" />
      {reason === "missing-harness" && (
        <>
          {/* A prompt with nothing behind it, and the download arrow Install brings. */}
          <path d="M11 18l4 3-4 3" className="acpmux-start-recovery-stroke" />
          <path d="M30 15v11m-4.5-4.5L30 26l4.5-4.5" className="acpmux-start-recovery-accent" />
          <path d="M25 30h10" className="acpmux-start-recovery-accent" />
        </>
      )}
      {reason === "signed-out" && (
        <>
          {/* A person and a key: sign in. */}
          <circle cx="18" cy="19" r="4" className="acpmux-start-recovery-stroke" />
          <path d="M11 31c1.5-4 4-5.5 7-5.5s5.5 1.5 7 5.5" className="acpmux-start-recovery-stroke" />
          <circle cx="32" cy="22" r="3" className="acpmux-start-recovery-accent" />
          <path d="M32 25v6m0-2.5h2.5" className="acpmux-start-recovery-accent" />
        </>
      )}
      {reason === "offline" && (
        <>
          {/* A signal with a break in it: the connection, not the agent. */}
          <path d="M14 22a14 14 0 0 1 20 0" className="acpmux-start-recovery-stroke" />
          <path d="M18 26a8.5 8.5 0 0 1 12 0" className="acpmux-start-recovery-stroke" />
          <circle cx="24" cy="30" r="1.6" className="acpmux-start-recovery-fill" />
          <path d="M33 14l-18 20" className="acpmux-start-recovery-accent" />
        </>
      )}
    </svg>
  );
}
