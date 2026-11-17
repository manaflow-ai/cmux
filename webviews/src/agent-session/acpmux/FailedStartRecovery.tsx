import { useT } from "./i18n";
import { StartRecovery, type StartRecoveryLook } from "./StartRecovery";
import { startFailureView } from "./startFailure";
import type { FailedStart } from "./startRecoveryReason";

/// A failed start that is signed out or offline (startRecoveryReason.ts), in the shared start-recovery
/// view. Signed out: Sign In opens the agent's own login, then Try Again starts the chat; the
/// sign-in is never automatic. Offline: Try Again starts the same chat again; the message the
/// failed start handed back stays in the composer, so nothing reads as sent before it is.
export function FailedStartRecovery({
  start,
  reason,
  onSignIn,
  onRetry,
  onDismiss,
  look,
}: {
  start: FailedStart;
  reason: "signed-out" | "offline";
  /// Opens the agent's login; absent when cmux knows no login for it here (then Try Again leads).
  onSignIn?(): void;
  onRetry(): void;
  onDismiss?(): void;
  look?: StartRecoveryLook;
}) {
  const t = useT();
  const view = startFailureView(t, start);
  const sentence = reason === "signed-out" ? t("missingHarness.signIn", { harness: start.name }) : view.sentence;
  const signIn = reason === "signed-out" && onSignIn;
  return (
    <StartRecovery
      reason={reason}
      sentence={sentence}
      {...(view.detail ? { detail: view.detail } : {})}
      actions={
        <>
          {signIn && (
            <button type="button" data-recovery-action="signIn" onClick={onSignIn}>
              {t("harnesses.signIn")}
            </button>
          )}
          <button type="button" data-recovery-action="retry" data-secondary={signIn ? "" : undefined} onClick={onRetry}>
            {t("harness.tryAgain")}
          </button>
        </>
      }
      {...(onDismiss ? { onDismiss } : {})}
      {...(look ? { look } : {})}
    />
  );
}
