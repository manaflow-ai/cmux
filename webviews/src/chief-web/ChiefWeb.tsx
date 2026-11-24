import "../agent-session/guest/guest.css";
import "./chief-web.css";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useAutoRetry } from "../agent-session/acpmux/autoRetry";
import { useLasting } from "../ui/lasting";
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
  /** Reloads the page once a chunk load failed twice (tests hand in a spy). */
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
/// The failed loads after which the page reloads (once): the browser may keep a failed module fetch
/// for the page's life (#38101 F1), so asking the same import again cannot land.
const CHUNK_RELOAD_AFTER = 2;
/// The tab's last reload for a failed chunk; one within `CHUNK_RELOAD_GAP_MS` keeps asking instead,
/// so a chunk that cannot load anywhere never reloads the page in a loop.
const CHUNK_RELOAD_KEY = "cmux.chief.chunkReloadAt";
const CHUNK_RELOAD_GAP_MS = 5 * 60_000;
const reloadWindow = () => window.location.reload();
interface ChunkLoad {
  delay: number;
  /// The failed loads before this one.
  failures: number;
}

/// Whether this tab may reload for a failed chunk now, and if so records that it did.
function mayReloadForChunk(): boolean {
  try {
    const last = Number(window.sessionStorage.getItem(CHUNK_RELOAD_KEY) ?? 0);
    if (Date.now() - last < CHUNK_RELOAD_GAP_MS) return false;
    window.sessionStorage.setItem(CHUNK_RELOAD_KEY, String(Date.now()));
    return true;
  } catch {
    return false;
  }
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
  const [loading, setLoading] = useState(true);
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

  // One read of who this is per attempt. A Chief that did not answer is asked again on its own
  // (`useAutoRetry`: jittered backoff, paused while the page is hidden), so "offline" stays set across
  // the asks and only a stretch that lasts the deadline says one quiet line, with no Retry (Leo,
  // 2026-11-22: "vacuous decisions like that should be just done").
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    void api
      .me(controller.signal)
      .then((me) => {
        if (controller.signal.aborted) return;
        setFailed(undefined);
        setIdentity(me);
      })
      .catch((error) => {
        if (controller.signal.aborted) return;
        if (error instanceof ExpiredSession) setFailed("expired");
        else if (error instanceof ChiefAccessError) setFailed("inaccessible");
        else setFailed("offline");
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });
    return () => controller.abort();
  }, [api, attempt]);
  const { stillTrying } = useAutoRetry(failed === "offline", () => setAttempt((value) => value + 1), {
    busy: loading,
  });

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
            ) : failed === "offline" && stillTrying ? (
              <p>{t("chiefWeb.stillTrying")}</p>
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
  // A failed load (a dropped connection) keeps trying on its own, 1 s, 2 s, 4 s ... up to 30 s apart,
  // as the guest page does, and says nothing until the failure has lasted (then one quiet line, no
  // Retry: Leo, 2026-11-22, "vacuous decisions like that should be just done"). The browser may keep a
  // failed module fetch for the page's life, so a load that failed `CHUNK_RELOAD_AFTER` times reloads
  // the page once.
  const [view, setView] = useState<TranscriptModule>();
  const [load, setLoad] = useState<ChunkLoad>(() => ({ delay: CHUNK_RETRY_FIRST_MS, failures: 0 }));
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
        if (load.failures + 1 === CHUNK_RELOAD_AFTER && mayReloadForChunk()) reloadPage();
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
      () => setLoad({ delay: Math.min(failedLoad.delay * 2, CHUNK_RETRY_MAX_MS), failures: failedLoad.failures + 1 }),
      failedLoad.delay,
    );
    return () => clearTimeout(retry);
  }, [failedLoad, load]);
  const stillLoading = useLasting(failedLoad !== undefined);
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

  // The wire reconnects on its own (wire.ts `reconnect`); a drop says nothing until it has lasted the
  // house deadline.
  const connecting = useLasting(connection === "connecting" || connection === "reconnecting");

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
          ) : connection !== "live" && connecting ? (
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
          ) : (
            <div className="chief-web__empty">
              <Spinner size={20} />
              {stillLoading && <output className="chief-web__still-loading">{t("guest.live.stillLoading")}</output>}
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
                {/* retry-prompt-ok: re-sends the person's refused message (a paid Chief turn) */}
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
