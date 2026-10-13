// The Channels page connected straight to its cmux instance (`?daemon=ws://host:port`): the person
// either pastes the instance's credential or pairs this browser with a code they approve in cmux.
// The credential stays in this tab's sessionStorage, never in the URL. Then the page runs on the
// daemon's real conversations, and the instance bar controls that instance (a new workspace).
import { useEffect, useState, type ReactNode } from "react";
import { DaemonSocket, type DaemonAuth } from "../shared/daemonSocket";
import type { Strings } from "../shared/i18n";

const storageKey = (url: string) => `cmux.daemon.credential:${url}`;

type Phase =
  | { kind: "form"; error?: string }
  | { kind: "connecting" }
  | { kind: "pairing"; code: string }
  | { kind: "ready"; daemon: DaemonSocket };

export function DaemonGate({ url, strings, children }: {
  url: string;
  strings: Strings;
  children: (daemon: DaemonSocket) => ReactNode;
}) {
  const { t, format } = strings;
  const [phase, setPhase] = useState<Phase>(() =>
    sessionStorage.getItem(storageKey(url)) ? { kind: "connecting" } : { kind: "form" },
  );
  const [credential, setCredential] = useState("");

  const connect = (auth: DaemonAuth, remember?: string) => {
    DaemonSocket.connect(url, auth)
      .then(async (daemon) => {
        await daemon.request("identify");
        if (remember) sessionStorage.setItem(storageKey(url), remember);
        setPhase({ kind: "ready", daemon });
      })
      .catch((error: Error) => {
        sessionStorage.removeItem(storageKey(url));
        setPhase({ kind: "form", error: error.message });
      });
  };

  // A credential this tab already holds reconnects at once (a reload keeps the session).
  useEffect(() => {
    const saved = sessionStorage.getItem(storageKey(url));
    if (saved) connect({ token: saved }, saved);
    // Runs once per endpoint.
  }, [url]);

  if (phase.kind === "ready") return <>{children(phase.daemon)}</>;
  return (
    <div className="hc-gate" role="dialog" aria-labelledby="hc-gate-title">
      <h1 id="hc-gate-title">{t("connect.title")}</h1>
      <p className="hc-gate-endpoint">{url}</p>
      {phase.kind === "pairing" && <p className="hc-gate-code">{format("connect.pairingCode", phase.code)}</p>}
      {phase.kind === "connecting" && <p>{t("connect.connecting")}</p>}
      {phase.kind === "form" && (
        <form
          onSubmit={(event) => {
            event.preventDefault();
            const value = credential.trim();
            if (!value) return;
            setPhase({ kind: "connecting" });
            connect({ token: value }, value);
          }}
        >
          <label>
            {t("connect.credential")}
            <input
              type="password"
              autoComplete="off"
              value={credential}
              onChange={(event) => setCredential(event.target.value)}
            />
          </label>
          <div className="hc-gate-actions">
            <button type="submit">{t("connect.button")}</button>
            <button
              type="button"
              onClick={() => {
                setPhase({ kind: "connecting" });
                connect({
                  pair: {
                    onChallenge: (code) => setPhase({ kind: "pairing", code }),
                    onCredential: (value) => sessionStorage.setItem(storageKey(url), value),
                  },
                });
              }}
            >
              {t("connect.pair")}
            </button>
          </div>
          {phase.error && <p className="hc-gate-error">{format("connect.failed", phase.error)}</p>}
        </form>
      )}
    </div>
  );
}

/** One control of the connected instance: its workspace count and a new workspace. */
export function InstanceBar({ daemon, strings }: { daemon: DaemonSocket; strings: Strings }) {
  const { t, format } = strings;
  const [count, setCount] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = () =>
    daemon
      .request<{ workspaces?: unknown[] }>("list-workspaces")
      .then((tree) => setCount(tree.workspaces?.length ?? 0))
      .catch(() => setCount(null));

  useEffect(() => {
    void refresh();
    // The tree changes reach every subscriber; one reread per change keeps the count true.
    return daemon.onEvent((event) => {
      if (event.event === "tree-changed" || event.event === "workspace-changed") void refresh();
    });
  }, [daemon]);

  return (
    <div className="hc-instance" role="toolbar" aria-label={t("instance.label")}>
      <span>{count === null ? t("instance.label") : format("instance.workspaces", String(count))}</span>
      <button
        type="button"
        disabled={busy}
        onClick={() => {
          setBusy(true);
          daemon
            .request("new-workspace", {})
            .then(refresh)
            .finally(() => setBusy(false));
        }}
      >
        {t("instance.newWorkspace")}
      </button>
    </div>
  );
}
