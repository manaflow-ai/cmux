import "../agent-session/guest/guest.css";
import "./chief-web.css";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { Spinner } from "../agent-session/acpmux/conversation/icons";
import { ArrowUpIcon } from "../agent-session/acpmux/icons/arrowUpIcon";
import { useT } from "../agent-session/acpmux/i18n";
import { GuestComposer } from "../agent-session/guest/GuestComposer";
import { GuestPrompts } from "../agent-session/guest/guestPrompts";
import { chiefApi, type ChiefApi } from "./api";
import { ChiefOutbox } from "./outbox";
import { MachineSignIn } from "./MachineSignIn";
import { machineLoginApi, type MachineLoginApi } from "./machineLogin";
import { ChiefTranscript } from "./transcript";
import {
  ChiefWire,
  ChiefAccessError,
  ExpiredSession,
  type ChiefConnection,
  type ChiefIdentity,
  type SocketLike,
} from "./wire";

export interface ChiefWebProps {
  api?: ChiefApi;
  storage?: Storage;
  loginApi?: MachineLoginApi;
  openSocket?: (url: string, protocols: string[]) => SocketLike;
  /** Loads the transcript's chunk (loadChiefTranscript; tests and the gallery hand in a failing one). */
  loadTranscript?: () => Promise<TranscriptModule>;
  /** Reloads the page when Retry's load fails too (tests hand in a spy). */
  reloadPage?: () => void;
}

const signIn = () => location.assign(location.pathname);

type TranscriptModule = typeof import("./ChiefTranscriptView");
let transcriptChunk: Promise<TranscriptModule> | undefined;
/**
 * Loads the transcript's chunk once (ChiefTranscriptView.tsx); a failed load is forgotten, so the next
 * call tries again. The import is its own step, as on the guest page (GuestPage.tsx loadGuestTranscript):
 * the bundler wraps `import()` with its preload of the chunk's modules.
 */
export function loadChiefTranscript(): Promise<TranscriptModule> {
  const fetchChunk = async (): Promise<TranscriptModule> => import("./ChiefTranscriptView");
  transcriptChunk ??= fetchChunk().catch((error: unknown) => {
    transcriptChunk = undefined;
    throw error;
  });
  return transcriptChunk;
}

/** Tries to load the transcript's chunk again after a failed load: 1 s, 2 s, 4 s ... up to 30 s apart. */
const CHUNK_RETRY_FIRST_MS = 1_000;
const CHUNK_RETRY_MAX_MS = 30_000;
const reloadWindow = () => window.location.reload();
interface ChunkLoad {
  delay: number;
  byRetry: boolean;
}

function browserStorage(): Storage {
  try {
    return window.sessionStorage;
  } catch {
    const values = new Map<string, string>();
    return {
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => {
        values.set(key, value);
      },
      removeItem: (key) => {
        values.delete(key);
      },
      clear: () => values.clear(),
      key: (index) => [...values.keys()][index] ?? null,
      get length() {
        return values.size;
      },
    };
  }
}

export function ChiefWeb({
  api = chiefApi,
  loginApi = machineLoginApi,
  storage,
  openSocket,
  loadTranscript = loadChiefTranscript,
  reloadPage = reloadWindow,
}: ChiefWebProps) {
  const t = useT();
  const [identity, setIdentity] = useState<ChiefIdentity>();
  const [failed, setFailed] = useState<"expired" | "offline" | "inaccessible">();
  const [attempt, setAttempt] = useState(0);
  const saved = useMemo(() => storage ?? browserStorage(), [storage]);
  const frame = useRef<HTMLDivElement>(null);

  // Safari's layout viewport keeps its old height while the keyboard is up. Size and lift only
  // this page to the visual viewport; no scrolling, focus stealing, or animation loop.
  useLayoutEffect(() => {
    const viewport = window.visualViewport;
    const resize = () => {
      frame.current?.style.setProperty("--chief-height", `${viewport?.height ?? window.innerHeight}px`);
      frame.current?.style.setProperty("--chief-top", `${viewport?.offsetTop ?? 0}px`);
    };
    resize();
    viewport?.addEventListener("resize", resize);
    viewport?.addEventListener("scroll", resize);
    window.addEventListener("resize", resize);
    return () => {
      viewport?.removeEventListener("resize", resize);
      viewport?.removeEventListener("scroll", resize);
      window.removeEventListener("resize", resize);
    };
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let retries = 0;
    setFailed(undefined);
    const load = () => {
      void api
        .me(controller.signal)
        .then((me) => {
          if (!controller.signal.aborted) setIdentity(me);
        })
        .catch((error) => {
          if (controller.signal.aborted) return;
          if (error instanceof ExpiredSession) setFailed("expired");
          else if (error instanceof ChiefAccessError) setFailed("inaccessible");
          else {
            setFailed("offline");
            timer = setTimeout(load, Math.min(30_000, 1_000 * 2 ** Math.min(retries++, 5)));
          }
        });
    };
    load();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [api, attempt]);

  return (
    <div ref={frame} className="chief-web" data-testid="chief-web">
      {identity ? (
        <ChiefChat
          key={`${identity.chiefId}:${identity.mainConversationId}`}
          identity={identity}
          api={api}
          loginApi={loginApi}
          storage={saved}
          openSocket={openSocket}
          loadTranscript={loadTranscript}
          reloadPage={reloadPage}
        />
      ) : (
        <>
          <header className="chief-web__header">
            <h1>{t("needsYou.chief")}</h1>
          </header>
          <main className="chief-web__empty">
            {failed === "expired" ? (
              <>
                <h2>{t("harnesses.signedOut")}</h2>
                <button className="chief-web__action" onClick={signIn}>
                  {t("turn.signInAgain")}
                </button>
              </>
            ) : failed === "inaccessible" ? (
              <p role="alert">{t("chiefWeb.notYours")}</p>
            ) : failed === "offline" ? (
              <>
                <p>{t("chiefWeb.unavailable")}</p>
                <button className="chief-web__action" onClick={() => setAttempt((value) => value + 1)}>
                  {t("retry.action")}
                </button>
              </>
            ) : (
              <Spinner size={20} />
            )}
          </main>
        </>
      )}
    </div>
  );
}

function ChiefChat({
  identity,
  api,
  loginApi,
  storage,
  openSocket,
  loadTranscript,
  reloadPage,
}: {
  identity: ChiefIdentity;
  api: ChiefApi;
  loginApi: MachineLoginApi;
  storage: Storage;
  openSocket?: ChiefWebProps["openSocket"];
  loadTranscript: () => Promise<TranscriptModule>;
  reloadPage: () => void;
}) {
  const t = useT();
  const [transcript] = useState(() => new ChiefTranscript());
  const { rows, working } = useSyncExternalStore(transcript.subscribe, transcript.snapshot);
  const [connection, setConnection] = useState<ChiefConnection>("connecting");
  const [loginRun, setLoginRun] = useState<string>();
  const [expanded, setExpanded] = useState(() => new Set<string>());
  // The transcript's chunk loads beside the ticket and the socket, so it is in before the first rows.
  // A failed load (a dropped connection) says so with Retry and keeps trying on its own, 1 s, 2 s, 4 s
  // ... up to 30 s apart, as the guest page does. The browser may keep a failed module fetch for the
  // page's life, so a Retry that fails again reloads the page.
  const [view, setView] = useState<TranscriptModule>();
  // Each load is its own attempt; Retry's (byRetry) reloads the page when it fails too.
  const [load, setLoad] = useState<ChunkLoad>(() => ({ delay: CHUNK_RETRY_FIRST_MS, byRetry: false }));
  const [failedLoad, setFailedLoad] = useState<ChunkLoad>();
  useEffect(() => {
    let stopped = false;
    void loadTranscript().then(
      (chunk) => {
        if (stopped) return;
        setFailedLoad(undefined);
        setView(() => chunk);
      },
      () => {
        // A newer attempt (or an unmount) stopped this one.
        if (stopped) return;
        if (load.byRetry) reloadPage();
        else setFailedLoad(load);
      },
    );
    return () => {
      stopped = true;
    };
  }, [loadTranscript, reloadPage, load]);
  useEffect(() => {
    if (!failedLoad || failedLoad !== load) return;
    const retry = setTimeout(
      () => setLoad({ delay: Math.min(failedLoad.delay * 2, CHUNK_RETRY_MAX_MS), byRetry: false }),
      failedLoad.delay,
    );
    return () => clearTimeout(retry);
  }, [failedLoad, load]);
  const loadFailed = failedLoad !== undefined;
  const retryLoad = () => setLoad({ delay: CHUNK_RETRY_FIRST_MS, byRetry: true });
  const [confirmed, setConfirmed] = useState(() => new Set<string>());
  const prompts = useMemo(
    () => new GuestPrompts(`chief:${identity.chiefId}:${identity.mainConversationId}`, storage),
    [identity, storage],
  );
  const mine = useSyncExternalStore(prompts.subscribe, prompts.list);
  const wire = useRef<ChiefWire | undefined>(undefined);
  const queue = useRef<ChiefOutbox | undefined>(undefined);

  useEffect(() => {
    const controller = new AbortController();
    const outbox = new ChiefOutbox(prompts, api, (state) => {
      client.stop();
      controller.abort();
      setConnection(state);
    });
    const client = new ChiefWire(
      { identity, ticket: () => api.ticket(controller.signal), open: openSocket },
      {
        rows: transcript.update,
        machineLogin: setLoginRun,
        accepted: (clientId) => {
          outbox.accepted(clientId);
          setConfirmed((previous) => new Set(previous).add(clientId));
        },
        connection: (state) => {
          setConnection(state);
          if (state === "live") outbox.connected();
          else outbox.disconnected();
          if (state === "expired" || state === "inaccessible") {
            outbox.stop();
            controller.abort();
          }
        },
      },
    );
    queue.current = outbox;
    wire.current = client;
    client.connect();
    return () => {
      controller.abort();
      outbox.stop();
      client.stop();
    };
  }, [api, identity, prompts, openSocket, transcript]);

  const pending = mine.filter(
    (prompt) =>
      !confirmed.has(prompt.clientId) &&
      (prompt.state === "sending" || prompt.state === "refused" || prompt.state === "approved"),
  );
  return (
    <>
      <header className="chief-web__header">
        <h1>{t("needsYou.chief")}</h1>
        <output className="chief-web__connection">
          {connection === "expired" ? (
            <>
              <span>{t("harnesses.signedOut")}</span>
              <button onClick={signIn}>{t("turn.signInAgain")}</button>
            </>
          ) : connection === "inaccessible" ? (
            <span role="alert">{t("chiefWeb.notYours")}</span>
          ) : connection === "offline" ? (
            <>
              <span>{t("chiefWeb.offline")}</span>
              <button onClick={() => wire.current?.retry()}>{t("retry.action")}</button>
            </>
          ) : connection !== "live" ? (
            <>
              <Spinner size={14} />
              <span>{connection === "connecting" ? t("guest.live.connecting") : t("guest.live.reconnecting")}</span>
            </>
          ) : null}
        </output>
      </header>
      <main className="chief-web__transcript" data-read-only-transcript="">
        {rows.length ? (
          view ? (
            <view.ChiefTranscriptView
              transcript={transcript}
              rows={rows}
              sessionId={`chief-web:${identity.mainConversationId}`}
              expanded={expanded}
              setExpanded={setExpanded}
              working={working}
            />
          ) : loadFailed ? (
            <div className="chief-web__empty" role="alert">
              <p>{t("guest.live.loadFailed")}</p>
              <button className="chief-web__action" onClick={retryLoad}>
                {t("retry.action")}
              </button>
            </div>
          ) : (
            <div className="chief-web__empty">
              <Spinner size={20} />
            </div>
          )
        ) : (
          <div className="chief-web__empty">
            <h2>{t("chiefWeb.empty")}</h2>
          </div>
        )}
      </main>
      <div className="chief-web__dock">
        {loginRun && connection !== "expired" && connection !== "inaccessible" && (
          <MachineSignIn
            key={loginRun}
            run={loginRun}
            api={loginApi}
            onExpired={() => {
              wire.current?.stop();
              queue.current?.stop();
              setConnection("expired");
            }}
          />
        )}
        {pending.length > 0 && (
          <section className="chief-web__outbox" aria-live="polite">
            {pending.map((prompt) => (
              <div className="chief-web__pending" key={prompt.clientId}>
                <p>{prompt.text}</p>
                <span>
                  {prompt.state === "sending"
                    ? t("guest.prompt.sending")
                    : prompt.state === "approved"
                      ? t("message.sent")
                      : t("chiefWeb.notSent")}
                </span>
                {prompt.state === "refused" && (
                  <button
                    onClick={() => {
                      prompts.retry(prompt.clientId);
                      queue.current?.queued();
                    }}
                  >
                    {t("retry.action")}
                  </button>
                )}
              </div>
            ))}
          </section>
        )}
        <GuestComposer
          className="ui-glass"
          onSend={(text) => {
            prompts.add(text);
            queue.current?.queued();
          }}
          onDraft={() => undefined}
          placeholder={t("chiefWeb.placeholder")}
          sendIcon={<ArrowUpIcon />}
          disabled={connection === "expired" || connection === "inaccessible"}
          enterSends={false}
        />
      </div>
    </>
  );
}
