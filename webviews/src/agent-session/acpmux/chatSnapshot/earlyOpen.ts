// The pane's handshake with the app (`ready`) and its socket's open (`transport.open`), asked by the
// page's first classic script (boot.ts) instead of by the bundle once it ran: the bundle takes about
// 340 ms to load and run after a restart, and the host's handshake and the socket's open go on
// meanwhile (Leo, 2026-11-22: "get that gui agent chat sped up to be nearly as fast as the terminal
// coming back"). The bundle takes each answer once (native.ts `postNative` takes the `ready`,
// bridgeSocket.ts the open), only within `EARLY_OPEN_FRESH_MS` of the ask; past that, or for any
// other ask, it asks the host itself as before. An open nobody took is closed.
//
// On that socket the boot script also sends the chat's first requests, the bundle's own frames
// (`initialize`, then the chat's attach and its draft read, as direct.ts `askEarly` sends them), and
// keeps every frame that comes back (`EarlyWire`); the bundle's socket takes them (earlyWire.ts):
// each request of the bundle that is the same frame as one sent here is answered by that answer
// instead of going out again (Leo, 2026-11-22: "where the fuck is the cached thing + delta + simply
// showing the rendered appearance and the bare interactivity or whatever and then gradually loading
// the rest in but still doing that asap"). Shared by the boot script and the bundle, so it imports
// only modules that import nothing (attachParams.ts, initializeParams.ts).
import { HOLD_ATTACH_CAPABILITY, OPEN_PAGE_BYTES, SETTLED_ATTACH_CAPABILITY, plainAttach } from "../attachParams";
import { initializeParams } from "../initializeParams";

/// The global the boot script sets: the early asks and whether the bundle took them.
export const EARLY_OPEN_GLOBAL = "__cmuxEarlyOpen";
/// How long after the boot's ask the bundle may still take its answers; an open untaken by then is
/// closed. Longer than the bundle's load on a busy launch (about 340 ms on a fleet VM).
export const EARLY_OPEN_FRESH_MS = 10_000;
/// Ids the boot's page-host calls use, far from the page client's own (it counts from 1).
const EARLY_CALL_ID = 1_000_000_000;

/// A host reply as the old `agentSession` handler gives it.
export type EarlyReply = { ok: true; value: unknown } | { ok: false; error?: unknown };

export type EarlyOpen = {
  /// `performance.now()` of the ask.
  at: number;
  ready: Promise<EarlyReply>;
  /// The connection the open answered, undefined when it failed. Asked only once `ready` answered
  /// for the app's transport (`acpmux-bridge`), in that answer's turn, at `openAt`: a handshake that
  /// waits on a starting daemon answers late, and its socket is still the bundle's to take.
  open?: Promise<number | undefined>;
  openAt?: number;
  readyTaken?: boolean;
  openTaken?: boolean;
  /// The requests sent on the open's socket and what came back, once the open answered.
  wire?: EarlyWire;
  /// The clock `at` and `openAt` are on (`performance.now()`; a test's own).
  now: () => number;
};

type Handler = { postMessage(body: unknown): Promise<unknown> };

function handlers(): { page?: Handler; agent?: Handler } {
  const found = (self as { webkit?: { messageHandlers?: Record<string, Handler | undefined> } }).webkit
    ?.messageHandlers;
  const usable = (handler: Handler | undefined) => (typeof handler?.postMessage === "function" ? handler : undefined);
  return { page: usable(found?.cmuxPage), agent: usable(found?.agentSession) };
}

/// One host call by the route the bundle's `postNative` takes: the shared page host first
/// (pageHost.ts, `cmux.agent.*`), else the old `agentSession` handler.
function call(method: string, params: Record<string, unknown>, id: number): Promise<EarlyReply> {
  const { page, agent } = handlers();
  if (page)
    return page
      .postMessage({ t: "call", id, op: `cmux.agent.${method === "ready" ? "handshake" : method}`, params })
      .then((reply) => {
        const message = reply as { t?: unknown; id?: unknown; value?: unknown } | null;
        return message?.t === "ok" && message.id === id
          ? { ok: true as const, value: message.value }
          : { ok: false as const, error: reply };
      });
  if (agent)
    return agent
      .postMessage({ id: `early-${id}`, method, params })
      .then((reply) => (reply as EarlyReply | null) ?? { ok: false as const });
  return Promise.resolve({ ok: false as const });
}

/// Asks the handshake and the socket now, on a page the app hosts. Not on a parked spare (no routes
/// yet; it holds every call until the claim, pageClient.ts) or a page that asked already.
export function askEarlyOpen(now: () => number = () => performance.now()): void {
  const globals = self as unknown as Record<string, unknown>;
  if (globals[EARLY_OPEN_GLOBAL] || globals.__cmuxPageParked === true) return;
  const { page, agent } = handlers();
  if (!page && !agent) return;
  const early: EarlyOpen = {
    now,
    at: now(),
    ready: call("ready", {}, EARLY_CALL_ID).catch(() => ({ ok: false as const })),
  };
  globals[EARLY_OPEN_GLOBAL] = early;
  void early.ready.then((reply) => {
    const transport = reply.ok ? (reply.value as { transport?: unknown } | null)?.transport : undefined;
    if (transport !== "acpmux-bridge") return;
    const open = call("transport.open", {}, EARLY_CALL_ID + 1).then(
      (answer) => {
        const connection = answer.ok ? (answer.value as { connection?: unknown } | null)?.connection : undefined;
        return typeof connection === "number" ? connection : undefined;
      },
      () => undefined,
    );
    early.open = open;
    early.openAt = now();
    const ready = reply.ok ? (reply.value as Record<string, unknown> | null) : null;
    void open.then((connection) => {
      if (connection !== undefined && !early.openTaken) early.wire = startWire(connection, ready ?? {}, now);
    });
    // An open the bundle never took is closed once it can no longer take it: the host's connection
    // never runs on with no page to read it.
    void open.then((connection) => {
      if (connection === undefined) return;
      const left = Math.max(0, (early.openAt ?? early.at) + EARLY_OPEN_FRESH_MS - now());
      // timeout: the bound past which the bundle no longer takes the open (`takeEarlyOpen`).
      setTimeout(() => {
        if (early.openTaken) return;
        early.openTaken = true;
        void call("transport.close", { connection }, EARLY_CALL_ID + 2).catch(() => undefined);
      }, left);
    });
  });
}

function fresh(early: EarlyOpen | undefined, now: number, since = early?.at): early is EarlyOpen {
  return !!early && since !== undefined && now - since <= EARLY_OPEN_FRESH_MS;
}

/// The boot's `ready` answer for the bundle's first handshake, once, when it is fresh and the host
/// took it; undefined otherwise (the bundle asks itself). A refusal is not taken: the bundle asks
/// again, as its retries do, and the open that rode it is never taken either.
export function takeEarlyReady(): Promise<EarlyReply> | undefined {
  const early = (self as unknown as Record<string, EarlyOpen | undefined>)[EARLY_OPEN_GLOBAL];
  if (!early || !fresh(early, early.now()) || early.readyTaken) return undefined;
  early.readyTaken = true;
  return early.ready;
}

/// The boot's open for the socket of the handshake the bundle took (`takeEarlyReady`), once, within
/// the bound of its ask; undefined otherwise. The host keeps one connection per handshake, so this socket is
/// that handshake's: an open of the bundle's own would be refused.
export function takeEarlyOpen(): Promise<number | undefined> | undefined {
  const early = (self as unknown as Record<string, EarlyOpen | undefined>)[EARLY_OPEN_GLOBAL];
  if (!early || !fresh(early, early.now(), early.openAt) || !early.readyTaken || early.openTaken || !early.open)
    return undefined;
  early.openTaken = true;
  return early.open;
}

/// A host push for one connection (bridgeSocket.ts `TransportEvent`).
export type EarlyEvent = { connection: number; frames?: string[]; closed?: { code: number; reason: string; error?: string } };

/// One request the boot script sent: its JSON-RPC id, method, params as JSON, and when.
export type EarlyAsk = { id: number; method: string; params: string; at: number };

/// The boot script's requests on the early socket and every push for it, in order, until the bundle
/// takes them with the open (`takeEarlyWire`); nothing more is sent once it did.
export type EarlyWire = {
  connection: number;
  asks: EarlyAsk[];
  inbox: EarlyEvent[];
  /// The chat the early attach is of (its `_acpmux/event` records ride the attach).
  session?: string;
  taken?: boolean;
  now: () => number;
};

/// JSON-RPC ids of the boot's requests, far from the bundle's (direct.ts counts from 1).
export const EARLY_RPC_ID = 2_000_000_000;
/// The receiver the boot script installs as `window.cmuxAcpmuxTransport` until the bundle's own.
export const EARLY_RECEIVER = "early";

/// Sends `initialize` on the early socket and, once it answers, the chat's attach and its draft
/// read: the frames the bundle's client sends first (direct.ts `open`, `askEarly`).
function startWire(connection: number, ready: Record<string, unknown>, now: () => number): EarlyWire | undefined {
  const w = self as unknown as { cmuxAcpmuxTransport?: { receive(event: EarlyEvent): void; [EARLY_RECEIVER]?: true } };
  // A page whose transport receiver is up already is the bundle's: it asks its own.
  if (w.cmuxAcpmuxTransport) return undefined;
  const wire: EarlyWire = { connection, asks: [], inbox: [], now };
  let sends = 0;
  const send = (requests: { method: string; params: Record<string, unknown> }[]) => {
    if (wire.taken || !requests.length) return;
    const frames = requests.map(({ method, params }) => {
      const id = EARLY_RPC_ID + wire.asks.length;
      wire.asks.push({ id, method, params: JSON.stringify(params), at: now() });
      return JSON.stringify({ jsonrpc: "2.0", id, method, params });
    });
    sends += 1;
    void call("transport.send", { connection, frames }, EARLY_CALL_ID + 2 + sends).catch(() => undefined);
  };
  const sessionId = typeof ready.sessionId === "string" && ready.sessionId ? ready.sessionId : undefined;
  // A new chat, an adopt and a chat named by no id open no chat on the handshake: only `initialize`.
  const opensChat = sessionId !== undefined && !ready.newSession && (ready.adopt === undefined || ready.adopt === null);
  let answered = false;
  w.cmuxAcpmuxTransport = {
    [EARLY_RECEIVER]: true,
    receive(event: EarlyEvent) {
      if (!event || event.connection !== connection) return;
      wire.inbox.push(event);
      if (answered || wire.taken || !opensChat) return;
      for (const frame of event.frames ?? []) {
        let reply: { id?: unknown; result?: { _meta?: { acpmux?: { capabilities?: unknown; origin?: unknown } } } };
        try {
          reply = JSON.parse(frame);
        } catch {
          continue;
        }
        if (reply?.id !== EARLY_RPC_ID) continue;
        answered = true;
        const meta = reply.result?._meta?.acpmux;
        // A failed handshake sends nothing more: the bundle's own handles it.
        if (!reply.result) return;
        const capabilities = Array.isArray(meta?.capabilities) ? meta.capabilities.map(String) : [];
        const requests: { method: string; params: Record<string, unknown> }[] = [];
        // An acpmux with the row store's hold asks the app's switch before its attach (direct.ts
        // `sendAttachAfterSwitch`), whose answer picks the hold or the plain page: neither is known
        // here, so only the draft read goes. Every other one sends the plain attach the bundle sends.
        if (!capabilities.includes(HOLD_ATTACH_CAPABILITY)) {
          wire.session = sessionId;
          requests.push({
            method: "_acpmux/attach",
            params: plainAttach(sessionId!, {
              settled: capabilities.includes(SETTLED_ATTACH_CAPABILITY),
              // direct.ts `readerHere`: the page shows; the reader counts as here until two idle minutes pass.
              visible: typeof document === "undefined" || document.visibilityState !== "hidden",
              local: meta?.origin === "local",
              maxBytes: OPEN_PAGE_BYTES,
            }) as unknown as Record<string, unknown>,
          });
        }
        requests.push({ method: "_acpmux/draft_get", params: { sessionId } });
        send(requests);
        return;
      }
    },
  };
  send([{ method: "initialize", params: initializeParams() }]);
  return wire;
}

/// The early socket's requests and pushes, for the bundle's socket that took its open
/// (`takeEarlyOpen`), once: the boot script sends nothing more after it.
export function takeEarlyWire(): EarlyWire | undefined {
  const early = (self as unknown as Record<string, EarlyOpen | undefined>)[EARLY_OPEN_GLOBAL];
  const wire = early?.wire;
  if (!wire || wire.taken) return undefined;
  wire.taken = true;
  return wire;
}
