// The Channels page connected straight to its cmux instance over the daemon WebSocket. In a plain
// browser (`?daemon=ws://host:port`, or the page the daemon serves itself at /pages/home-channels/)
// the person either pastes the instance's credential or pairs this browser with a code they approve
// in cmux; the credential stays in this tab's sessionStorage, never in the URL. A same-origin endpoint
// whose server answers `GET /auth/session` with `{"authorized": true}` (a relay that identified the
// person, for example by a private-network identity, and attaches the credential upstream itself)
// connects with no credential and no form. In the app the host
// hands the endpoint and the daemon's own credential (`cmux.host.credential.load`, a host verb), and
// `owner` when this build's Chief conversations live on the Chief home's owner: the page opens a
// second socket there for the local conversations (a credential bound to this page, single use, so
// every reconnect loads again).
// Then the page runs on the daemon's real conversations. A dropped connection reconnects with capped backoff and the same
// credential; each connection gets a fresh store (spec transports.md "Reconnect").
import { Fragment, useEffect, useRef, useState, type ReactNode } from "react";
import { DaemonSocket, type DaemonAuth } from "../shared/daemonSocket";
import type { Strings } from "../shared/i18n";
import { useLasting } from "../../ui/lasting";

const storageKey = (url: string) => `cmux.daemon.credential:${url}`;

/** The endpoint is this page's own origin (same host and port, ws for http, wss for https). */
function sameOrigin(url: string): boolean {
  try {
    const endpoint = new URL(url);
    const scheme = location.protocol === "https:" ? "wss:" : location.protocol === "http:" ? "ws:" : "";
    return endpoint.protocol === scheme && endpoint.host === location.host;
  } catch {
    return false;
  }
}

/** Whether this page's origin already authorized the person (`GET /auth/session`). Any other answer,
 *  a 404 from a daemon that serves the page itself included, means no: the form is shown. */
async function originAuthorized(): Promise<boolean> {
  try {
    const response = await fetch("/auth/session", { cache: "no-store", credentials: "same-origin" });
    if (!response.ok) return false;
    const body = (await response.json()) as { authorized?: unknown };
    return body.authorized === true;
  } catch {
    return false;
  }
}

/** The endpoint and credential the host hands the page (`cmux.host.credential.load`). */
export interface HostCredential {
  url: string;
  token: string;
  /** The page bundle URL a browser opens (`http://127.0.0.1:<port>/pages/`). */
  pages?: string;
  /** The local conversation owner when it is not this daemon (this build's Chief home's owner). */
  owner?: { url: string; token: string };
}

/** Where the page's daemon comes from: a URL the person authenticates, or the hosting app. */
export type DaemonSource = { kind: "url"; url: string } | { kind: "host"; load(): Promise<HostCredential> };

type Phase =
  | { kind: "form"; error?: string }
  | { kind: "connecting"; note?: string }
  | { kind: "pairing"; code: string }
  /** The host says this daemon cannot serve the page and cmux cannot fix it by itself: no retry loop. */
  | { kind: "blocked"; error: string }
  | { kind: "ready"; daemon: DaemonSocket; owner?: DaemonSocket; generation: number; pages?: string };

const BACKOFF_MIN_MS = 500;
const BACKOFF_MAX_MS = 10_000;

export function DaemonGate({
  source,
  strings,
  children,
}: {
  source: DaemonSource;
  strings: Strings;
  children: (daemon: DaemonSocket, pages?: string, owner?: DaemonSocket) => ReactNode;
}) {
  const { t, format } = strings;
  const url = source.kind === "url" ? source.url : "";
  const [phase, setPhase] = useState<Phase>(() =>
    source.kind === "host" || sessionStorage.getItem(storageKey(url)) || sameOrigin(url)
      ? { kind: "connecting" }
      : { kind: "form" },
  );
  const [credential, setCredential] = useState("");
  const live = useRef({
    mounted: true,
    attempt: 0,
    generation: 0,
    timer: 0 as ReturnType<typeof setTimeout> | 0,
    daemon: null as DaemonSocket | null,
    owner: null as DaemonSocket | null,
  });

  /** A socket that serves the conversations to a page: authenticated and new enough. `closed`
   *  says whether it closed before the page took it (a close listener added later never fires). */
  const open = (endpoint: string, auth: DaemonAuth) =>
    DaemonSocket.connect(endpoint, auth).then(async (daemon) => {
      let closed = false;
      daemon.onClose(() => (closed = true));
      try {
        const identity = await daemon.request<{ capabilities?: string[] }>("identify");
        // An older daemon refuses the conversations on a WebSocket: say so instead of failing later.
        if (!identity.capabilities?.includes("ws-conversations-v1")) throw new Error(t("connect.tooOld"));
      } catch (error) {
        daemon.close();
        throw error;
      }
      return { daemon, closed: () => closed };
    });

  /** One connect: authenticate, check the capability, then keep the socket until it drops. */
  const connect = (
    endpoint: string,
    auth: DaemonAuth,
    remember?: string,
    pages?: string,
    ownerCredential?: HostCredential["owner"],
  ) => {
    const opening = [
      open(endpoint, auth),
      ownerCredential ? open(ownerCredential.url, { token: ownerCredential.token }) : Promise.resolve(undefined),
    ] as const;
    Promise.allSettled(opening)
      .then(([main, second]) => {
        const opened = [main, second].flatMap((result) =>
          result.status === "fulfilled" && result.value ? [result.value] : [],
        );
        // Either socket failing (or closing already) fails the connect: the page never shows half of
        // its owners, and the socket that did open is closed, not leaked.
        const failed = main.status === "rejected" ? main : second.status === "rejected" ? second : null;
        if (failed || opened.some((socket) => socket.closed())) {
          for (const socket of opened) socket.daemon.close();
          throw failed ? failed.reason : Object.assign(new Error(t("connect.connecting")), { code: "unreachable" });
        }
        const daemon = (main as PromiseFulfilledResult<{ daemon: DaemonSocket }>).value.daemon;
        const owner = second.status === "fulfilled" ? second.value?.daemon : undefined;
        // Unmounted, or a newer connection already won: this one is not used.
        if (!live.current.mounted || live.current.daemon) {
          owner?.close();
          return daemon.close();
        }
        if (remember) sessionStorage.setItem(storageKey(endpoint), remember);
        live.current.attempt = 0;
        live.current.daemon = daemon;
        live.current.owner = owner ?? null;
        const generation = ++live.current.generation;
        const lost = (reason: string) => {
          if (!live.current.mounted || live.current.generation !== generation || live.current.daemon !== daemon) return;
          // One lost socket drops both: the reconnect loads fresh credentials for each.
          live.current.daemon = null;
          live.current.owner = null;
          daemon.close();
          owner?.close();
          if (reason === "authentication failed" && source.kind === "url") {
            sessionStorage.removeItem(storageKey(url));
            setPhase({ kind: "form", error: reason });
          } else retry();
        };
        daemon.onClose(lost);
        owner?.onClose(lost);
        setPhase({ kind: "ready", daemon, owner, generation, pages });
      })
      .catch((error: Error & { code?: string }) => {
        if (!live.current.mounted) return;
        // Only a refused credential is dropped; an unreachable daemon (a restart) keeps it.
        if (error.code === "auth_rejected" && source.kind === "url") {
          sessionStorage.removeItem(storageKey(url));
          setPhase({ kind: "form", error: error.message });
        } else if (error.code === "auth_rejected" || error.code === "unreachable" || source.kind === "host")
          retry(error.message);
        else setPhase({ kind: "form", error: error.message });
      });
  };

  /** Connects with what this tab (or the host) already holds, else shows the form. */
  const resume = () => {
    if (source.kind === "host") {
      source
        .load()
        .then((value) => connect(value.url, { token: value.token }, undefined, value.pages, value.owner))
        // The host says why it has no endpoint. A final answer (an external daemon too old for the
        // listener) stops here with the reason; anything else (a restart in progress) retries.
        .catch((error: Error & { retryable?: boolean }) => {
          if (error.retryable !== false) return retry(error.message);
          if (live.current.mounted) setPhase({ kind: "blocked", error: error.message });
        });
      return;
    }
    const saved = sessionStorage.getItem(storageKey(url));
    if (saved) connect(url, { token: saved }, saved);
    else if (sameOrigin(url))
      void originAuthorized().then((authorized) => {
        if (!live.current.mounted) return;
        if (authorized) connect(url, { origin: true });
        else setPhase({ kind: "form" });
      });
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
    // One object for the component's life (only its fields change), so the cleanup's copy is it.
    const state = live.current;
    state.mounted = true;
    resume();
    return () => {
      state.mounted = false;
      clearTimeout(state.timer);
      state.daemon?.close();
      state.owner?.close();
      state.daemon = null;
      state.owner = null;
    };
    // Runs once per endpoint.
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- resume is rebuilt each render; the effect runs once per endpoint.
  }, [url, source.kind]);

  // Connecting (a launch, the daemon or this build's Chief starting or restarting, a dropped link):
  // nothing shows while the retries can still outlast it. Only one that lasts past the grace is
  // said, as one muted line: the last attempt's reason, never in red, since the retries go on.
  const lasting = useLasting(phase.kind === "connecting");
  // A new store per connection: the key remounts the page on every reconnect.
  if (phase.kind === "ready")
    return <Fragment key={phase.generation}>{children(phase.daemon, phase.pages, phase.owner)}</Fragment>;
  if (phase.kind === "connecting")
    return (
      <section className="hc-gate" aria-busy="true">
        {lasting && (
          <output className="hc-gate-line">
            {phase.note ? format("connect.failed", phase.note) : t("connect.connecting")}
          </output>
        )}
      </section>
    );
  return (
    <section className="hc-gate" aria-labelledby="hc-gate-title">
      <h1 id="hc-gate-title">{t("connect.title")}</h1>
      {url && <p className="hc-gate-endpoint">{url}</p>}
      {phase.kind === "pairing" && <p className="hc-gate-code">{format("connect.pairingCode", phase.code)}</p>}
      {phase.kind === "blocked" && (
        <>
          <p className="hc-gate-error">{format("connect.failed", phase.error)}</p>
          <div className="hc-gate-actions">
            <button
              type="button"
              onClick={() => {
                setPhase({ kind: "connecting" });
                resume();
              }}
            >
              {t("connect.button")}
            </button>
          </div>
        </>
      )}
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
              aria-label={t("connect.credential")}
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
    </section>
  );
}
