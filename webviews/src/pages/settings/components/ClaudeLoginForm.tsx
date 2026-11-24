import { useEffect, useEffectEvent, useState } from "react";
import type { ModelsState } from "../ops";
import { t } from "../strings";
import { ConnectionError, ConnectionFooter, SecretField, SignInWaiting } from "./ModelConnectionFields";
import type { Run } from "./modelConnections";

function loginMessage(error: string) {
  switch (error) {
    case "machine_start_failed":
      return t("settingsWindow.models.claude.machineStartFailed");
    case "shared_machine":
      return t("settingsWindow.models.claude.shared");
    case "update_claude":
      return t("settingsWindow.models.claude.update");
    case "unsupported":
      return t("settingsWindow.models.claude.updateMachine");
    case "cli_missing":
      return t("settingsWindow.models.cloud.claudeMissing");
    case "expired":
      return t("settingsWindow.models.claude.expired");
    case "bad_code":
      return t("settingsWindow.models.cloud.codeInvalid");
    case "busy":
      return t("settingsWindow.models.claude.busy");
    default:
      return t("settingsWindow.models.claude.failed");
  }
}

export function ClaudeLoginForm({
  models,
  cloud,
  busy,
  run,
  onClose,
  onCancel,
  replace,
  error,
}: {
  models: ModelsState;
  cloud: boolean;
  busy: boolean;
  run: Run;
  onClose(): void;
  onCancel(): void;
  replace?: string;
  error: string | null;
}) {
  const login = cloud ? models.cloudClaudeLogin : models.claudeLogin;
  const phase = login?.phase ?? "idle";
  const [code, setCode] = useState("");
  const [started, setStarted] = useState(phase === "preparing" || phase === "approving" || phase === "code");
  const close = useEffectEvent(onClose);
  useEffect(() => {
    if (phase === "connected" && started) close();
  }, [phase, started]);

  const fallback = phase === "code";
  const disabled = phase === "disabled" || (phase === "connected" && !replace);
  const preparing = phase === "preparing";
  const waiting = preparing || phase === "approving" || phase === "cancelling";
  const valid = /^[!-~]{1,4096}$/.test(code.trim());
  const failure = error ?? (login?.error ? loginMessage(login.error) : undefined);
  const action = fallback ? "finishClaudeLogin" : "connectClaude";
  return (
    <form
      className="models-form"
      data-models-claude-form=""
      data-login={phase}
      onSubmit={(event) => {
        event.preventDefault();
        if (disabled || waiting || busy) return;
        if (fallback) {
          if (!valid) return;
          const value = code.trim();
          setCode("");
          void run({ action: "finishClaudeLogin", cloud, code: value });
        } else {
          setStarted(true);
          void run({ action: "connectClaude", cloud, ...(replace ? { replace } : {}) });
        }
      }}
    >
      {login?.machineName && <p className="row-help">{login.machineName}</p>}
      {phase === "connected" && <output className="row-help">{t("settingsWindow.models.claude.connected")}</output>}
      {preparing ? (
        <SignInWaiting title={t("settingsWindow.models.claude.preparing")} />
      ) : waiting ? (
        <SignInWaiting>
          {t(
            phase === "cancelling" ? "settingsWindow.models.cloud.cancelling" : "settingsWindow.models.waiting.browser",
          )}
        </SignInWaiting>
      ) : null}
      {fallback && (
        <SecretField
          label={t("settingsWindow.models.cloud.code")}
          value={code}
          onChange={setCode}
          disabled={busy}
          maxLength={4096}
        />
      )}
      {login?.apiKey && <p>{t("settingsWindow.models.claude.keyWins")}</p>}
      {failure && <ConnectionError>{failure}</ConnectionError>}
      <ConnectionFooter
        onClose={onCancel}
        busy={busy}
        disabled={disabled || (fallback && !valid)}
        failed={!disabled && !!failure}
        connectAction={action}
        loading={waiting || busy}
      />
    </form>
  );
}
