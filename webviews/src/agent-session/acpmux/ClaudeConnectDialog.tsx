// Connect your Claude subscription (claudeConnect.ts): run `claude setup-token`, paste the token it
// prints, optionally label it, then Verify and connect. The sheet is the picker's Add account sheet
// (addAccount.css: glass, title and lead, fields, the shared key-hint buttons); only the numbered
// steps and the command chip are its own (claudeConnect.css). Focus starts in the token field;
// Return submits, Escape cancels (ui/Dialog, ui/DialogButton), and the copy button says Copied
// with a check once the clipboard took the command (conversation/CopyButton).
import { useId, useRef, useState } from "react";
import { Dialog } from "../../ui/Dialog";
import { DialogButton } from "../../ui/DialogButton";
import { CLAUDE_SETUP_TOKEN_COMMAND } from "../shared/claudeSetupToken";
import { checkToken, connectRequest, refusalText, type ClaudeConnect } from "./claudeConnect";
import { CopyButton } from "./conversation/CopyButton";
import { useT } from "./i18n";
import "./addAccount.css";
import "./claudeConnect.css";

/// The shape of a setup token, as the field's placeholder: an invariant, never translated.
const TOKEN_PLACEHOLDER = "sk-ant-oat01-…";

export function ClaudeConnectDialog({
  add,
  onClose,
  onConnected,
  start,
}: {
  /// The host's check and save (ClaudeConnect.add): the dialog's only way out to the app.
  add: ClaudeConnect["add"];
  onClose(): void;
  /// The token was saved: the caller closes the dialog and marks the picker row connected.
  onConnected(): void;
  /// A gallery fixture's starting state; the app never passes it.
  start?: { token?: string; label?: string; pending?: boolean; error?: string };
}) {
  const t = useT();
  const ids = useId();
  const tokenField = useRef<HTMLInputElement | null>(null);
  const [token, setToken] = useState(start?.token ?? "");
  const [label, setLabel] = useState(start?.label ?? "");
  const [pending, setPending] = useState(start?.pending ?? false);
  const [error, setError] = useState<string | undefined>(start?.error);
  const sending = useRef(false);
  const check = checkToken(token);
  const ready = check === "valid" && !pending;
  const cancel = () => {
    if (pending) return;
    setToken("");
    onClose();
  };
  const submit = () => {
    if (sending.current || !ready) return;
    const request = connectRequest(token, label);
    // The token lives only in the open form until it is sent (ModelsCard.tsx ClaudeTokenForm).
    setToken("");
    sending.current = true;
    setPending(true);
    setError(undefined);
    // Invoked in the submit's turn so a native one-use gesture still belongs to this request.
    void add(request.token, request.label).then(onConnected, (failure: unknown) => {
      sending.current = false;
      setPending(false);
      setError(t("picker.connectClaude.failed", { reason: refusalText(failure, t("picker.connectClaude.refused")) }));
      tokenField.current?.focus();
    });
  };
  const title = t("picker.connectClaude.title");
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) cancel();
      }}
      label={title}
      initialFocus={tokenField}
      className="ui-glass ui-glass-floats acpmux-add-account acpmux-connect-claude"
    >
      <form
        aria-busy={pending || undefined}
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <header>
          <h2>{title}</h2>
          <p>{t("picker.connectClaude.detail")}</p>
        </header>
        <ol className="acpmux-connect-claude-steps">
          <li>
            <span className="acpmux-connect-claude-step">{t("picker.connectClaude.step1")}</span>
            <span className="acpmux-connect-claude-command">
              <code className="selectable">{CLAUDE_SETUP_TOKEN_COMMAND}</code>
              <CopyButton
                text={CLAUDE_SETUP_TOKEN_COMMAND}
                label={t("picker.connectClaude.copy")}
                className="ui-button ui-btn acpmux-connect-claude-copy"
                size={14}
              />
            </span>
          </li>
          <li>
            <label className="acpmux-add-account-field" htmlFor={`${ids}-token`}>
              <span className="acpmux-connect-claude-step">{t("picker.connectClaude.step2")}</span>
              <input
                ref={tokenField}
                id={`${ids}-token`}
                aria-label={t("picker.connectClaude.step2")}
                name="token"
                type="password"
                value={token}
                placeholder={TOKEN_PLACEHOLDER}
                maxLength={4096}
                disabled={pending}
                autoComplete="off"
                spellCheck={false}
                aria-invalid={check === "invalid" || undefined}
                aria-describedby={`${ids}-token-help`}
                onChange={(event) => {
                  setToken(event.target.value);
                  setError(undefined);
                }}
              />
              {check === "invalid" ? (
                <small id={`${ids}-token-help`} role="alert" className="acpmux-add-account-error">
                  {t("picker.connectClaude.invalid")}
                </small>
              ) : (
                <small id={`${ids}-token-help`}>{t("picker.connectClaude.tokenHint")}</small>
              )}
            </label>
            <label className="acpmux-add-account-field" htmlFor={`${ids}-label`}>
              <span className="acpmux-connect-claude-step">{t("picker.connectClaude.label")}</span>
              <input
                id={`${ids}-label`}
                aria-label={t("picker.connectClaude.label")}
                name="label"
                value={label}
                placeholder={t("picker.connectClaude.labelPlaceholder")}
                maxLength={128}
                disabled={pending}
                autoComplete="off"
                spellCheck={false}
                aria-describedby={`${ids}-label-help`}
                onChange={(event) => setLabel(event.target.value)}
              />
              <small id={`${ids}-label-help`}>{t("picker.connectClaude.labelHint")}</small>
            </label>
          </li>
        </ol>
        {error && (
          <p role="alert" className="acpmux-add-account-error" data-connect-refused="">
            {error}
          </p>
        )}
        <footer>
          <DialogButton
            dialogKey="escape"
            className="ui-button ui-btn"
            data-variant="subtle"
            data-size="md"
            data-disabled={pending ? "" : undefined}
            disabled={pending}
            onClick={cancel}
          >
            {t("switch.cancelPrompt")}
          </DialogButton>
          <DialogButton
            dialogKey="return"
            type="submit"
            className="ui-button ui-btn"
            data-variant="solid"
            data-size="md"
            data-disabled={!ready ? "" : undefined}
            data-busy={pending ? "" : undefined}
            disabled={!ready}
          >
            {pending ? t("picker.connectClaude.verifying") : t("picker.connectClaude.submit")}
          </DialogButton>
        </footer>
      </form>
    </Dialog>
  );
}
