import { useState, type FormEvent } from "react";
import { t } from "../i18n";
import type { ConnectionConfig } from "../hooks/useCmuxClient";

interface ConnectScreenProps {
  connecting: boolean;
  error: string | null;
  onConnect(config: ConnectionConfig): void;
}

export function ConnectScreen({ connecting, error, onConnect }: ConnectScreenProps) {
  const [url, setUrl] = useState("ws://127.0.0.1:7681");
  const [token, setToken] = useState("");
  const submit = (event: FormEvent) => {
    event.preventDefault();
    onConnect({ url: url.trim(), token: token.trim() || undefined });
  };

  return (
    <main className="connect-shell">
      <form className="connect-card" onSubmit={submit}>
        <div className="brand-mark" aria-hidden="true">›_</div>
        <h1>{t("appName")}</h1>
        <p>{t("appTagline")}</p>
        <label>
          <span>{t("wsUrl")}</span>
          <input type="url" value={url} onChange={(event) => setUrl(event.target.value)} required spellCheck={false} />
        </label>
        <label>
          <span>{t("token")}</span>
          <input type="password" value={token} onChange={(event) => setToken(event.target.value)} autoComplete="off" />
        </label>
        {error && <div className="inline-error" role="alert">{error || t("unknownError")}</div>}
        <button type="submit" disabled={connecting}>{connecting ? t("connecting") : t("connect")}</button>
      </form>
    </main>
  );
}
