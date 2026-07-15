import { useState, type FormEvent } from "react";
import { t } from "../i18n";
import type { ConnectionConfig } from "../hooks/useCmuxClient";
import { initialConnectionConfig, rememberWebSocketUrl } from "../lib/connectionDefaults";

interface ConnectScreenProps {
  connecting: boolean;
  error: string | null;
  onConnect(config: ConnectionConfig): void;
}

export function ConnectScreen({ connecting, error, onConnect }: ConnectScreenProps) {
  const [initial] = useState(() => {
    const config = initialConnectionConfig(window.location, window.localStorage);
    // Credentials must not linger in the address bar / history / bookmarks:
    // consume ?ws= and ?token= once, then replace with the cleaned URL. The
    // token lives in memory only from here on.
    const params = new URLSearchParams(window.location.search);
    if (params.has("ws") || params.has("token")) {
      params.delete("ws");
      params.delete("token");
      const search = params.toString();
      window.history.replaceState(
        null,
        "",
        window.location.pathname + (search ? `?${search}` : "") + window.location.hash,
      );
    }
    return config;
  });
  const [url, setUrl] = useState(initial.url);
  const [token, setToken] = useState(initial.token);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    const normalizedUrl = url.trim();
    rememberWebSocketUrl(normalizedUrl, window.localStorage);
    onConnect({ url: normalizedUrl, token: token.trim() || undefined });
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
        <label>
          <span>{t("token")}</span>
          <input
            type="password"
            value={token}
            onChange={(event) => setToken(event.target.value)}
            autoComplete="off"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="go"
          />
        </label>
        {error && <div className="inline-error" role="alert">{error || t("unknownError")}</div>}
        <button type="submit" disabled={connecting}>{connecting ? t("connecting") : t("connect")}</button>
      </form>
    </main>
  );
}
