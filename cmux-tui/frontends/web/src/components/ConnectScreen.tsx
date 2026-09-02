import { useState, type FormEvent } from "react";
import { t } from "../i18n";
import type { ConnectionConfig } from "../hooks/useCmuxClient";
import {
  initialConnectionConfig,
  rememberWebSocketUrl,
} from "../lib/connectionDefaults";
import type { PairingChallenge } from "cmux/raw";

interface ConnectScreenProps {
  connecting: boolean;
  error: string | null;
  pairing: PairingChallenge | null;
  onConnect(config: ConnectionConfig): void;
}

function removeTokenFragment(hash: string): string {
  const fragment = hash.replace(/^#/, "");
  return fragment
    .split("&")
    .filter((part) => !new URLSearchParams(part).has("token"))
    .join("&");
}

export function ConnectScreen({ connecting, error, pairing, onConnect }: ConnectScreenProps) {
  const runtimeHint = new URLSearchParams(window.location.search).get("runtime") === "mac"
    ? "mac"
    : "tui";
  const [initial] = useState(() => {
    const config = initialConnectionConfig(window.location, window.localStorage, runtimeHint);
    // Consume the one-tap socket query and credential fragment once. The token
    // never enters the HTTP request and lives in memory only from here on.
    const params = new URLSearchParams(window.location.search);
    const fragment = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    if (params.has("ws") || params.has("token") || fragment.has("token")) {
      params.delete("ws");
      params.delete("token");
      const search = params.toString();
      const hash = removeTokenFragment(window.location.hash);
      window.history.replaceState(
        null,
        "",
        window.location.pathname + (search ? `?${search}` : "") + (hash ? `#${hash}` : ""),
      );
    }
    return config;
  });
  const [runtime, setRuntime] = useState<"tui" | "mac">(runtimeHint);
  const [url, setUrl] = useState(initial.url);
  const [tuiToken] = useState(runtimeHint === "tui" ? initial.token : "");
  const [bridgeToken, setBridgeToken] = useState(runtimeHint === "mac" ? initial.token : "");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const normalizedUrl = url.trim();
    rememberWebSocketUrl(normalizedUrl, window.localStorage, runtime);
    const locationParams = new URLSearchParams(window.location.search);
    if (runtime === "mac") locationParams.set("runtime", "mac");
    else locationParams.delete("runtime");
    const persistedSearch = locationParams.toString();
    window.history.replaceState(
      null,
      "",
      window.location.pathname
        + (persistedSearch ? `?${persistedSearch}` : "")
        + window.location.hash,
    );
    const config: ConnectionConfig = {
      url: normalizedUrl,
      token: runtime === "mac" ? bridgeToken.trim() || undefined : tuiToken || undefined,
    };
    if (runtime === "mac") config.runtime = "mac";
    onConnect(config);
  };

  return (
    <main className="connect-shell">
      <form autoComplete="off" className="connect-card" onSubmit={submit}>
        <div className="brand-mark" aria-hidden="true">›_</div>
        <h1>{t("appName")}</h1>
        <p>{t("appTagline")}</p>
        <label>
          <span>{t("runtime")}</span>
          <select
            value={runtime}
            onChange={(event) => {
              const nextRuntime = event.target.value as "tui" | "mac";
              const currentSuggested = initialConnectionConfig(
                window.location,
                window.localStorage,
                runtime,
              ).url;
              if (url === currentSuggested) {
                setUrl(initialConnectionConfig(
                  window.location,
                  window.localStorage,
                  nextRuntime,
                ).url);
              }
              setRuntime(nextRuntime);
            }}
          >
            <option value="tui">{t("runtimeTui")}</option>
            <option value="mac">{t("runtimeMac")}</option>
          </select>
        </label>
        <label>
          <span>{t("wsUrl")}</span>
          <input
            type="url"
            value={url}
            onChange={(event) => setUrl(event.target.value)}
            required
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="go"
          />
        </label>
        {runtime === "mac" && (
          <label>
            <span>{t("bridgeToken")}</span>
            <input
              type="password"
              value={bridgeToken}
              onChange={(event) => setBridgeToken(event.target.value)}
              required
              autoComplete="off"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
              placeholder={t("bridgeTokenHelp")}
            />
          </label>
        )}
        {pairing && (
          <div className="pairing-code" role="status">
            <span>{t("pairingPrompt")}</span>
            <strong>{pairing.code}</strong>
            <small>{t("pairingExpires", { seconds: pairing.expiresIn })}</small>
          </div>
        )}
        {error && <div className="inline-error" role="alert">{error || t("unknownError")}</div>}
        <button type="submit" disabled={connecting || pairing !== null}>
          {pairing ? t("waitingForApproval") : connecting ? t("connecting") : t("connect")}
        </button>
      </form>
    </main>
  );
}
