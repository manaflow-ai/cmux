import { useRef } from "react";
import { Dialog } from "../../../ui/Dialog";
import { DialogButton } from "../../../ui/DialogButton";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { AgentMark } from "../../shared/AgentMark";
import type { HarnessInstallState } from "./useHarnessInstall";

/// The model picker's install prompt (cmux#38191): a model of a harness this Mac does not have was
/// picked. It names the harness and the command Install runs; Install runs it in place with its
/// last output line as progress; a failure says why and offers Try Again (and the setup page when
/// the harness has one). Hide leaves an install running: the pick lands when it ends. A harness that
/// installs signed out asks for its sign-in first (Sign In runs its login in a terminal tab).
export function HarnessInstallDialog({
  state,
  onInstall,
  onCancel,
  onSetupGuide,
  onSignIn,
}: {
  state: HarnessInstallState;
  onInstall(): void;
  /// Cancel before an install, Hide during one, Close after a failure.
  onCancel(): void;
  onSetupGuide?(): void;
  /// After the install, when the harness is signed out: its login in a terminal tab, then the pick.
  onSignIn(): void;
}) {
  const t = useT();
  const primary = useRef<HTMLButtonElement | null>(null);
  const { target, phase } = state;
  const installing = phase.kind === "installing";
  const failed = phase.kind === "failed";
  const signingIn = phase.kind === "signIn";
  const title = signingIn
    ? t("harnessInstall.signInTitle", { harness: target.name })
    : t("harnessInstall.title", { harness: target.name });
  return (
    <Dialog
      open={state.open}
      onOpenChange={(next) => {
        if (!next) onCancel();
      }}
      label={title}
      className="ui-glass ui-glass-floats acpmux-install-dialog"
      initialFocus={primary}
    >
      <header className="acpmux-install-dialog-head">
        <AgentMark agent={target.mark} size={20} reserve />
        <h2>{title}</h2>
      </header>
      {signingIn ? (
        <p>{t("harnessInstall.signInBody", { harness: target.name })}</p>
      ) : target.command ? (
        <>
          <p>{t("harnessInstall.body", { harness: target.name })}</p>
          <code className="acpmux-install-dialog-command" data-install-command>
            {target.command}
          </code>
        </>
      ) : (
        <p>{t("harnessInstall.noInstaller", { harness: target.name })}</p>
      )}
      {installing && (
        <output className="acpmux-install-dialog-status" data-install-status="installing">
          <Spinner size={12} loading />
          <span>{phase.line ?? t("harnesses.installing")}</span>
        </output>
      )}
      {failed && (
        <p
          className="acpmux-install-dialog-status is-error"
          role="alert"
          data-install-status="failed"
          title={phase.reason}
        >
          {t("harnesses.commandFailedBecause", { reason: phase.reason })}
        </p>
      )}
      <div className="acpmux-install-dialog-actions">
        {failed && onSetupGuide && (
          <DialogButton
            dialogKey={null}
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            onClick={onSetupGuide}
          >
            {t("harnesses.setupGuide")}
          </DialogButton>
        )}
        <DialogButton
          dialogKey="escape"
          className="ui-button ui-btn"
          data-variant="subtle"
          data-size="md"
          onClick={onCancel}
        >
          {installing
            ? t("harnessInstall.hide")
            : failed
              ? t("harnesses.close")
              : signingIn
                ? t("harnessInstall.later")
                : t("harnessInstall.cancel")}
        </DialogButton>
        {signingIn ? (
          <DialogButton
            ref={primary}
            dialogKey="return"
            className="ui-button ui-btn"
            data-variant="solid"
            data-size="md"
            onClick={onSignIn}
          >
            {t("harnesses.signIn")}
          </DialogButton>
        ) : (
          !installing &&
          (target.command || onSetupGuide) && (
            <DialogButton
              ref={primary}
              dialogKey="return"
              className="ui-button ui-btn"
              data-variant="solid"
              data-size="md"
              onClick={target.command ? onInstall : onSetupGuide}
            >
              {target.command
                ? failed
                  ? t("harnessInstall.retry")
                  : t("harnessInstall.install")
                : t("harnesses.setupGuide")}
            </DialogButton>
          )
        )}
      </div>
    </Dialog>
  );
}
