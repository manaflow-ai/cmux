import "../agent-session/guest/guest.css";
import "./chief-web.css";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { VirtualTranscript } from "../agent-session/acpmux/App";
import { GuestActionsBoundary } from "../agent-session/acpmux/conversation/GuestActionsBoundary";
import { Spinner } from "../agent-session/acpmux/conversation/icons";
import { ArrowUpIcon } from "../agent-session/acpmux/ComposerPickers";
import type { AcpmuxRow } from "../agent-session/acpmux/model";
import { GuestComposer } from "../agent-session/guest/GuestComposer";
import { GuestPrompts } from "../agent-session/guest/guestPrompts";
import { GuestSendQueue } from "../agent-session/guest/guestSendQueue";
import { chiefApi, SendRefused, type ChiefApi } from "./api";
import { ChiefWire, ExpiredSession, type ChiefIdentity, type SocketLike } from "./wire";

export interface ChiefWebProps {
  api?: ChiefApi;
  storage?: Storage;
  openSocket?: (url: string, protocols: string[]) => SocketLike;
}

const signIn = () => `/login?returnTo=${encodeURIComponent(location.pathname)}`;

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

export function ChiefWeb({ api = chiefApi, storage, openSocket }: ChiefWebProps) {
  const [identity, setIdentity] = useState<ChiefIdentity>();
  const [failed, setFailed] = useState<"expired" | "offline">();
  const [attempt, setAttempt] = useState(0);
  const saved = useMemo(() => storage ?? browserStorage(), [storage]);
  const frame = useRef<HTMLDivElement>(null);

  // Safari's layout viewport keeps its old height while the keyboard is up. Size and lift only
  // this page to the visual viewport; no scrolling, focus stealing, or animation loop.
  useLayoutEffect(() => {
    const viewport = window.visualViewport;
    const resize = () => {
      frame.current?.style.setProperty(
        "--chief-height",
        `${viewport?.height ?? window.innerHeight}px`,
      );
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
    setFailed(undefined);
    void api
      .me(controller.signal)
      .then((me) => {
        if (!controller.signal.aborted) setIdentity(me);
      })
      .catch((error) => {
        if (!controller.signal.aborted)
          setFailed(error instanceof ExpiredSession ? "expired" : "offline");
      });
    return () => controller.abort();
  }, [api, attempt]);

  return (
    <div ref={frame} className="chief-web" data-testid="chief-web">
      {identity ? (
        <ChiefChat
          key={`${identity.userId}:${identity.conversationId}`}
          identity={identity}
          api={api}
          storage={saved}
          openSocket={openSocket}
        />
      ) : (
        <>
          <header className="chief-web__header">
            <h1>Chief</h1>
          </header>
          <main className="chief-web__empty">
            {failed === "expired" ? (
              <>
                <h2>Sign in to your Chief</h2>
                <a className="chief-web__action" href={signIn()}>
                  Sign in
                </a>
              </>
            ) : failed === "offline" ? (
              <>
                <p>Offline</p>
                <button
                  className="chief-web__action"
                  onClick={() => setAttempt((value) => value + 1)}
                >
                  Retry
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
  storage,
  openSocket,
}: {
  identity: ChiefIdentity;
  api: ChiefApi;
  storage: Storage;
  openSocket?: ChiefWebProps["openSocket"];
}) {
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  const [connection, setConnection] = useState("connecting");
  const [expanded, setExpanded] = useState(() => new Set<string>());
  const [confirmed, setConfirmed] = useState(() => new Set<string>());
  const prompts = useMemo(
    () => new GuestPrompts(`chief:${identity.userId}:${identity.conversationId}`, storage),
    [identity, storage],
  );
  const mine = useSyncExternalStore(prompts.subscribe, prompts.list);
  const wire = useRef<ChiefWire | undefined>(undefined);
  const queue = useRef<GuestSendQueue | undefined>(undefined);

  useEffect(() => {
    const controller = new AbortController();
    let sending = Promise.resolve();
    const outbox = new GuestSendQueue(prompts, (prompt) => {
      // Preserve composer order even when the first HTTP send takes longer than the queue gap.
      sending = sending.then(() => {
        if (controller.signal.aborted) return;
        return api
          .send(prompt.text, prompt.clientId, controller.signal)
          .then(() => {
            if (!controller.signal.aborted)
              outbox.status({ client_id: prompt.clientId, state: "approved" });
          })
          .catch((error) => {
            if (controller.signal.aborted) return;
            if (error instanceof ExpiredSession) {
              client.stop();
              outbox.disconnected();
              controller.abort();
              setConnection("expired");
            } else if (error instanceof SendRefused)
              outbox.status({ client_id: prompt.clientId, state: "refused" });
            else
              outbox.status({
                client_id: prompt.clientId,
                state: "refused",
                reason: "share.rate_limited",
              });
          });
      });
      return true;
    });
    const client = new ChiefWire(
      { identity, ticket: () => api.ticket(controller.signal), open: openSocket },
      {
        rows: setRows,
        accepted: (clientId) => {
          outbox.status({ client_id: clientId, state: "approved" });
          setConfirmed((previous) => new Set(previous).add(clientId));
        },
        connection: (state) => {
          setConnection(state);
          if (state === "live") outbox.snapshot([]);
          else outbox.disconnected();
          if (state === "expired") controller.abort();
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
  }, [api, identity, prompts, openSocket]);

  const working = rows.some((row) => row.streaming);
  const pending = mine.filter(
    (prompt) =>
      !confirmed.has(prompt.clientId) &&
      (prompt.state === "sending" || prompt.state === "refused" || prompt.state === "approved"),
  );
  return (
    <GuestActionsBoundary>
      <header className="chief-web__header">
        <h1>Chief</h1>
        <output className="chief-web__connection">
          {connection === "expired" ? (
            <a href={signIn()}>Sign in again</a>
          ) : connection === "offline" ? (
            <>
              <span>Offline</span>
              <button onClick={() => wire.current?.retry()}>Retry</button>
            </>
          ) : connection !== "live" ? (
            <>
              <Spinner size={14} />
              <span>{connection === "connecting" ? "Connecting…" : "Reconnecting…"}</span>
            </>
          ) : null}
        </output>
      </header>
      <main className="chief-web__transcript" data-read-only-transcript="">
        {rows.length ? (
          <VirtualTranscript
            rows={rows}
            sessionId={`chief-web:${identity.conversationId}`}
            expanded={expanded}
            onToggleActivity={(id) =>
              setExpanded((open) => {
                const next = new Set(open);
                if (!next.delete(id)) next.add(id);
                return next;
              })
            }
            working={working}
            readOnly
          />
        ) : (
          <div className="chief-web__empty">
            <h2>Ask your Chief to build something</h2>
          </div>
        )}
      </main>
      <div className="chief-web__dock">
        {pending.length > 0 && (
          <section className="chief-web__outbox" aria-live="polite">
            {pending.map((prompt) => (
              <div className="chief-web__pending" key={prompt.clientId}>
                <p>{prompt.text}</p>
                <span>
                  {prompt.state === "sending"
                    ? "Sending…"
                    : prompt.state === "approved"
                      ? "Sent"
                      : "Message not sent"}
                </span>
                {prompt.state === "refused" && (
                  <button
                    onClick={() => {
                      prompts.retry(prompt.clientId);
                      queue.current?.queued();
                    }}
                  >
                    Retry
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
          placeholder="Message your Chief"
          sendIcon={<ArrowUpIcon />}
          disabled={connection === "expired"}
          enterSends={false}
        />
      </div>
    </GuestActionsBoundary>
  );
}
