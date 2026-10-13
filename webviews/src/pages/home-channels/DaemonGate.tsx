// The Channels page connected straight to its cmux instance over the daemon WebSocket. In a plain
// browser (`?daemon=ws://host:port`, or the page the daemon serves itself at /pages/home-channels/)
// the person either pastes the instance's credential or pairs this browser with a code they approve
// in cmux; the credential stays in this tab's sessionStorage, never in the URL. In the app the host
// hands the endpoint and the daemon's own credential (`cmux.host.credential.load`, a host verb).
// Then the page runs on the daemon's real conversations, and the instance bar controls that
// instance (a new workspace). A dropped connection reconnects with capped backoff and the same
// credential; each connection gets a fresh store (spec transports.md "Reconnect").
import { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { DaemonSocket, type DaemonAuth } from "../shared/daemonSocket";
import type { Strings } from "../shared/i18n";

const storageKey = (url: string) => `cmux.daemon.credential:${url}`;

/** The endpoint and credential the host hands the page (`cmux.host.credential.load`). */
export interface HostCredential {
  url: string;
  token: string;
  /** The page bundle URL a browser opens (`http://127.0.0.1:<port>/pages/`). */
  pages?: string;
}

/** Where the page's daemon comes from: a URL the person authenticates, or the hosting app. */
export type DaemonSource = { kind: "url"; url: string } | { kind: "host"; load(): Promise<HostCredential> };

type Phase =
  | { kind: "form"; error?: string }
  | { kind: "connecting"; note?: string }
  | { kind: "pairing"; code: string }
  | { kind: "ready"; daemon: DaemonSocket; generation: number; pages?: string };

const BACKOFF_MIN_MS = 500;
const BACKOFF_MAX_MS = 10_000;

export function DaemonGate({ source, strings, children }: {
  source: DaemonSource;
  strings: Strings;
  children: (daemon: DaemonSocket, pages?: string) => ReactNode;
}) {
  const { t, format } = strings;
  const url = source.kind === "url" ? source.url : "";
  const [phase, setPhase] = useState<Phase>(() =>
    source.kind === "host" || sessionStorage.getItem(storageKey(url)) ? { kind: "connecting" } : { kind: "form" },
  );
  const [credential, setCredential] = useState("");
  const live = useRef({
    mounted: true,
    attempt: 0,
    generation: 0,
    timer: 0 as ReturnType<typeof setTimeout> | 0,
    daemon: null as DaemonSocket | null,
  });

  /** One connect: authenticate, check the capability, then keep the socket until it drops. */
  const connect = (endpoint: string, auth: DaemonAuth, remember?: string, pages?: string) => {
    DaemonSocket.connect(endpoint, auth)
      .then(async (daemon) => {
        try {
          const identity = await daemon.request<{ capabilities?: string[] }>("identify");
          // An older daemon refuses the conversations on a WebSocket: say so instead of failing later.
          if (!identity.capabilities?.includes("ws-conversations-v1")) throw new Error(t("connect.tooOld"));
        } catch (error) {
          daemon.close();
          throw error;
        }
        // Unmounted, or a newer connection already won: this one is not used.
        if (!live.current.mounted || live.current.daemon) return daemon.close();
        if (remember) sessionStorage.setItem(storageKey(endpoint), remember);
        live.current.attempt = 0;
        live.current.daemon = daemon;
        const generation = ++live.current.generation;
        daemon.onClose((reason) => {
          if (!live.current.mounted || live.current.generation !== generation) return;
          live.current.daemon = null;
          if (reason === "authentication failed" && source.kind === "url") {
            sessionStorage.removeItem(storageKey(url));
            setPhase({ kind: "form", error: reason });
          } else retry();
        });
        setPhase({ kind: "ready", daemon, generation, pages });
      })
      .catch((error: Error & { code?: string }) => {
        if (!live.current.mounted) return;
        // Only a refused credential is dropped; an unreachable daemon (a restart) keeps it.
        if (error.code === "auth_rejected" && source.kind === "url") {
          sessionStorage.removeItem(storageKey(url));
          setPhase({ kind: "form", error: error.message });
        } else if (error.code === "auth_rejected" || error.code === "unreachable" || source.kind === "host") retry(error.message);
        else setPhase({ kind: "form", error: error.message });
      });
  };

  /** Connects with what this tab (or the host) already holds, else shows the form. */
  const resume = () => {
    if (source.kind === "host") {
      source
        .load()
        .then((value) => connect(value.url, { token: value.token }, undefined, value.pages))
        // The host says why it has no endpoint (an old daemon without the listener): show it.
        .catch((error: Error) => retry(error.message));
      return;
    }
    const saved = sessionStorage.getItem(storageKey(url));
    if (saved) connect(url, { token: saved }, saved);
    else setPhase({ kind: "form" });
  };

  /** Capped exponential backoff with jitter, one attempt in flight (spec transports.md "Reconnect"). */
  const retry = (note?: string) => {
    if (!live.current.mounted || live.current.daemon) return;
    setPhase({ kind: "connecting", note });
    const step = live.current.attempt++;
    const delay = Math.min(BACKOFF_MAX_MS, BACKOFF_MIN_MS * 2 ** step) * (0.5 + Math.random() / 2);
    clearTimeout(live.current.timer);
    live.current.timer = setTimeout(resume, delay);
  };

  // The first connect: a credential this tab (or the host) already holds reconnects at once.
  useEffect(() => {
    live.current.mounted = true;
    resume();
    return () => {
      live.current.mounted = false;
      clearTimeout(live.current.timer);
      live.current.daemon?.close();
      live.current.daemon = null;
    };
    // Runs once per endpoint.
  }, [url, source.kind]);

  // A new store per connection: the key remounts the page on every reconnect.
  if (phase.kind === "ready") return <Fragment key={phase.generation}>{children(phase.daemon, phase.pages)}</Fragment>;
  return (
    <div className="hc-gate" role="dialog" aria-labelledby="hc-gate-title">
      <h1 id="hc-gate-title">{t("connect.title")}</h1>
      {url && <p className="hc-gate-endpoint">{url}</p>}
      {phase.kind === "pairing" && <p className="hc-gate-code">{format("connect.pairingCode", phase.code)}</p>}
      {phase.kind === "connecting" && <p>{t("connect.connecting")}</p>}
      {phase.kind === "connecting" && phase.note && <p className="hc-gate-error">{format("connect.failed", phase.note)}</p>}
      {phase.kind === "form" && (
        <form
          onSubmit={(event) => {
            event.preventDefault();
            const value = credential.trim();
            if (!value) return;
            setPhase({ kind: "connecting" });
            connect(url, { token: value }, value);
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
                connect(url, {
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
export function InstanceBar({ daemon, strings, pageUrl }: { daemon: DaemonSocket; strings: Strings; pageUrl?: string }) {
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
      {/* In the app: the address a browser opens this page at (the person copies it). */}
      {pageUrl && <span className="hc-instance-url">{pageUrl}</span>}
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
