import { useState, type FormEvent } from "react";
import { t } from "../i18n";
import type { ConnectionConfig } from "../hooks/useCmuxClient";
import { initialConnectionConfig, rememberWebSocketUrl } from "../lib/connectionDefaults";
import type { PairingChallenge } from "cmux/browser";

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
  const [initial] = useState(() => {
    const config = initialConnectionConfig(window.location, window.localStorage);
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
  const [url, setUrl] = useState(initial.url);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const normalizedUrl = url.trim();
    rememberWebSocketUrl(normalizedUrl, window.localStorage);
    onConnect({ url: normalizedUrl, token: initial.token || undefined });
  };

  return (
    <main className="connect-shell">
      <form className="connect-card" onSubmit={submit}>
        <div className="brand-mark" aria-hidden="true">›_</div>
        <h1>{t("appName")}</h1>
        <p>{t("appTagline")}</p>
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
