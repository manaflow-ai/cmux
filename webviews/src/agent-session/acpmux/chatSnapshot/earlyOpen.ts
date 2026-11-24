// The pane's handshake with the app (`ready`) and its socket's open (`transport.open`), asked by the
// page's first classic script (boot.ts) instead of by the bundle once it ran: the bundle takes about
// 340 ms to load and run after a restart, and the host's handshake and the socket's open go on
// meanwhile (Leo, 2026-11-22: "get that gui agent chat sped up to be nearly as fast as the terminal
// coming back"). The bundle takes each answer once (native.ts `postNative` takes the `ready`,
// bridgeSocket.ts the open), only within `EARLY_OPEN_FRESH_MS` of the ask; past that, or for any
// other ask, it asks the host itself as before. An open nobody took is closed. Shared by the boot
// script and the bundle, so it imports nothing.

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
