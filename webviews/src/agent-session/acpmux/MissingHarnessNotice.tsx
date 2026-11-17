import type { ReactNode } from "react";
import { StartRecovery, type StartRecoveryLook } from "./StartRecovery";
import type { SetupPhase } from "./harnessSetup";
import { useT } from "./i18n";

/// A chat that could not start because its agent CLI is not on this Mac (Leo 2026-11-11: a friend
/// "tried to start a chat, didn't have Claude or Codex installed, ran into" setup text "and then
/// there was no recovery mechanism"). One true line and one way out, in the composer's notice slot,
/// where the start-failed card goes: Install runs the agent's installer in place (harnessSetup.ts,
/// the model picker's own install), signs in when it must, and then the message the person typed
/// goes; Use … instead starts the chat on an agent this Mac has. The Install click is the consent
/// to run an installer on the Mac: no command, no paragraph.
export type MissingHarnessNoticeProps = {
  /// The missing agent's name ("Claude Code").
  name: string;
  /// The install running for it (harnessSetup.ts), if one started.
  phase?: SetupPhase;
  /// cmux has an installer for it; without one the way out is the agents page (`onSetUp`).
  installable: boolean;
  /// An agent this Mac has that the chat can start on instead ("Codex").
  alternative?: string;
  onInstall(): void;
  onUseInstead?(): void;
  onSignIn(): void;
  /// The agents page, in this tab, for an agent cmux cannot install itself.
  onSetUp?(): void;
  /// Hides the view; focus goes back to the composer.
  onDismiss?(): void;
  look?: StartRecoveryLook;
};

export function MissingHarnessNotice({
  name,
  phase,
  installable,
  alternative,
  onInstall,
  onUseInstead,
  onSignIn,
  onSetUp,
  onDismiss,
  look,
}: MissingHarnessNoticeProps) {
  const t = useT();
  const instead = alternative && onUseInstead && (
    <button type="button" data-secondary="" data-missing-action="instead" onClick={onUseInstead}>
      {t("missingHarness.useInstead", { harness: alternative })}
    </button>
  );
  let text: string;
  let busy = false;
  let buttons: ReactNode = null;
  let detail: string | undefined;
  switch (phase?.kind) {
    case "installing":
      text = t("picker.setup.installing", { harness: name });
      busy = true;
      // The installer's last line, under the sentence while it runs (never a log).
      detail = phase.line;
      break;
    case "checking":
      text = t("picker.setup.checking", { harness: name });
      busy = true;
      break;
    case "ready":
      text = t("picker.setup.starting", { harness: name });
      busy = true;
      break;
    case "signIn":
      text = t("missingHarness.signIn", { harness: name });
      buttons = (
        <button type="button" data-missing-action="signIn" onClick={onSignIn}>
          {t("harnesses.signIn")}
        </button>
      );
      break;
    case "signingIn":
      text = t("picker.setup.signingIn", { harness: name });
      busy = true;
      break;
    case "failed":
      text = t("picker.setup.failed", { harness: name });
      detail = phase.reason ?? t(phase.reasonKey ?? "harnesses.commandFailed");
      buttons = (
        <>
          <button type="button" data-missing-action="install" onClick={onInstall}>
            {t("harness.tryAgain")}
          </button>
          {instead}
        </>
      );
      break;
    default:
      text = t("missingHarness.notInstalled", { harness: name });
      buttons = (
        <>
          {installable ? (
            <button type="button" data-missing-action="install" onClick={onInstall}>
              {t("missingHarness.install", { harness: name })}
            </button>
          ) : (
            onSetUp && (
              <button type="button" data-missing-action="setUp" onClick={onSetUp}>
                {t("missingHarness.setUp", { harness: name })}
              </button>
            )
          )}
          {instead}
        </>
      );
  }
  const running = phase?.kind === "installing";
  // The shared start-recovery view (StartRecovery.tsx): the picture follows the step, from a
  // missing agent to its sign-in, inside the same view.
  const signingIn = phase?.kind === "signIn" || phase?.kind === "signingIn";
  return (
    <StartRecovery
      reason={signingIn ? "signed-out" : "missing-harness"}
      sentence={text}
      busy={busy}
      {...(running && detail ? { line: detail } : {})}
      {...(!running && detail ? { detail } : {})}
      actions={buttons}
      {...(onDismiss ? { onDismiss } : {})}
      {...(look ? { look } : {})}
      className="acpmux-harness-notice acpmux-missing-harness"
      data={{ "data-missing-harness": phase?.kind ?? "missing" }}
    />
  );
}
