import { useEffect, useEffectEvent, useRef, useState, type ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import type { ChatGPTDeviceState, ModelDeviceProvider, ModelsState } from "../ops";
import { t } from "../strings";
import { ConnectionError, ConnectionFooter, SignInWaiting } from "./ModelConnectionFields";
import { chatgptErrorText, type Run } from "./modelConnections";

const successDisplayMs = 1500;

const providerNames: Record<ModelDeviceProvider, string> = {
  chatgpt: "ChatGPT",
  grok: "SuperGrok",
  copilot: "GitHub Copilot",
  kimi: "Kimi Code",
  openrouter: "OpenRouter",
};

export function ChatGPTDeviceForm({
  models,
  signIn,
  region,
  servesCloud,
  children,
  busy,
  run,
  onClose,
  onCancel,
  target,
  error,
}: {
  models: ModelsState;
  signIn: ModelDeviceProvider;
  region?: string;
  servesCloud?: boolean;
  children?: ReactNode;
  busy: boolean;
  run: Run;
  onClose(): void;
  onCancel(): void;
  target?: string;
  error: string | null;
}) {
  const state =
    (models.deviceProvider ?? "chatgpt") === signIn && (models.deviceTarget ?? undefined) === target
      ? models.chatgptDevice
      : undefined;
  const phase = state?.phase;
  const initialState = useRef(state);
  const [started, setStarted] = useState(phase === "starting" || phase === "waiting" || phase === "cancelling");
  const close = useEffectEvent(onClose);
  const connected = state?.phase === "connected" && started && state !== initialState.current;
  const account = models.personal.connections.find(
    (connection) =>
      (signIn === "openrouter" ? connection.provider === "openrouter" : connection.kind === `${signIn}-plan`) &&
      connection.id === (connected ? state.id : target),
  );
  useEffect(() => {
    if (!connected) return;
    const timer = setTimeout(() => close(), successDisplayMs);
    return () => clearTimeout(timer);
  }, [connected]);
  const expiresAt = state?.phase === "waiting" && state.userCode ? state.expiresAt : undefined;
  const [now, setNow] = useState(Date.now);
  const seconds = expiresAt === undefined ? undefined : Math.max(0, Math.ceil((expiresAt * 1000 - now) / 1000));
  useEffect(() => {
    if (expiresAt === undefined || seconds === 0) return;
    const timer = setTimeout(() => setNow(Date.now()), 1000);
    return () => clearTimeout(timer);
  }, [expiresAt, now, seconds]);
  const expired = seconds === 0 || (state?.phase === "failed" && state.error === "expired_token");
  const pending = phase === "starting" || (phase === "waiting" && !expired) || phase === "cancelling";
  const begin = () =>
    run({
      action: "connectChatGPTDevice",
      openBrowser: true,
      ...(signIn !== "chatgpt" && { provider: signIn }),
      ...(target && { id: target }),
      ...(region && { region }),
      ...(signIn === "openrouter" && servesCloud && { servesCloud: true }),
    });
  return (
    <form
      className="models-form"
      data-models-way={signIn}
      data-chatgpt-device={phase ?? "idle"}
      onSubmit={(event) => {
        event.preventDefault();
        if (busy || pending || connected) return;
        setStarted(true);
        void begin();
      }}
    >
      {children}
      {account?.email ? (
        <output className="row-help">{t("settingsWindow.models.chatgpt.deviceSignedIn", account.email)}</output>
      ) : connected ? (
        <output className="row-help">{t("settingsWindow.mcpServers.state.connected")}</output>
      ) : null}
      {state?.phase === "waiting" &&
        (state.userCode ? (
          <DeviceChallenge state={state} run={run} busy={busy} seconds={seconds ?? 0} />
        ) : (
          <SignInWaiting>{t("settingsWindow.models.waiting.browser")}</SignInWaiting>
        ))}
      {(phase === "starting" || phase === "cancelling") && (
        <div className="models-waiting">
          <output>
            {t(
              phase === "starting"
                ? "settingsWindow.models.chatgpt.deviceStarting"
                : "settingsWindow.models.cloud.cancelling",
            )}
          </output>
        </div>
      )}
      {(error || expired || state?.phase === "failed") && (
        <ConnectionError>
          {error ??
            (expired
              ? t(
                  signIn === "chatgpt"
                    ? "settingsWindow.models.chatgpt.deviceExpired"
                    : "settingsWindow.models.device.codeExpired",
                )
              : state?.phase === "failed"
                ? deviceFailure(signIn, state)
                : null)}
        </ConnectionError>
      )}
      <ConnectionFooter
        onClose={onCancel}
        busy={busy}
        disabled={connected}
        failed={!!error || expired || phase === "failed"}
        connectAction="connectChatGPTDevice"
        loading={pending || busy}
      />
    </form>
  );
}

function deviceFailure(provider: ModelDeviceProvider, state: Extract<ChatGPTDeviceState, { phase: "failed" }>) {
  switch (state.error) {
    case "keychain_locked":
      return t("settingsWindow.models.keychainLocked", providerNames[provider]);
    case "keychain_other_build":
      return t("settingsWindow.models.keychainOtherBuild");
    case "no_copilot_access":
      return t("settingsWindow.models.copilot.noAccess");
    case "enterprise_server":
      return t("settingsWindow.models.device.enterpriseServer");
    case "already_signed_in":
      if (provider !== "chatgpt") return t("settingsWindow.models.device.alreadyConnected", providerNames[provider]);
      break;
    case "different_account":
      if (state.actual && state.expected)
        return t("settingsWindow.models.device.wrongAccount", state.actual, state.expected);
      return t("settingsWindow.models.device.differentAccount");
    case "access_denied":
      if (provider !== "chatgpt") return t("settingsWindow.models.device.denied", providerNames[provider]);
      break;
    case "network":
      if (provider !== "chatgpt") return t("settingsWindow.models.device.network", providerNames[provider]);
      break;
    case "storage":
      return t("settingsWindow.models.device.storage");
    case "port_busy":
      return t("settingsWindow.models.device.portBusy");
  }
  return provider === "chatgpt" ? chatgptErrorText(state.error) : t("settingsWindow.mcpServers.error.notFinished");
}

function DeviceChallenge({
  state,
  run,
  busy,
  seconds,
}: {
  state: Extract<ChatGPTDeviceState, { phase: "waiting" }>;
  run: Run;
  busy: boolean;
  seconds: number;
}) {
  const store = useStore();
  const remaining = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  const [before, after] = t("settingsWindow.models.chatgpt.deviceEnter").split("%@");
  const site = URL.canParse(state.verificationURL) ? new URL(state.verificationURL).hostname : state.verificationURL;
  return (
    <div className="models-device-challenge">
      <div className="models-device-status">
        <code className="models-device-code selectable" dir="ltr">
          {state.userCode}
        </code>
        <Button size="sm" disabled={seconds === 0} onClick={() => void store.copy(state.userCode)}>
          {t("settingsWindow.agentTools.manual.copy")}
        </Button>
      </div>
      <div className="row-help">
        {before}
        <a
          className="channel-link"
          href={state.verificationURL}
          aria-disabled={busy || seconds === 0}
          onClick={(event) => {
            event.preventDefault();
            if (!busy && seconds > 0) void run({ action: "openChatGPTDevice" });
          }}
        >
          {site}
        </a>
        {after}
      </div>
      <SignInWaiting>
        <span dir="ltr" data-chatgpt-device-remaining="">
          {remaining}
        </span>
      </SignInWaiting>
    </div>
  );
}
