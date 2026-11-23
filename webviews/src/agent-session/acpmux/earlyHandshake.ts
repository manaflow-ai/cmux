// The pane's first handshake (`ready`) is asked before the App's modules evaluate and React's first
// commit, instead of from the pane's effect after them (pane/paneSnapshot.ts `connectHost`).
//
// Leo, 2026-11-22: "theoretically, it's all just text ... it should be able to be as fast as the
// terminal, or at least get close." A terminal attaches the moment it starts. The pane used to boot
// about 340 ms of JavaScript first (cmux#52006's floor bench: module evaluation and the App's first
// commit) and only then asked the host for its handshake. The host's half of the handshake (the
// daemon's handshake, the start folders, the wake read) then ran after that, serially. It now
// runs during the boot.
//
// This module is the first one `main.tsx` imports, so it must stay light: only the page client
// (17 modules, no stylesheets: the shipped sheet order is derived from the import order). It never
// imports `native.ts` or `pageHost.ts`, whose graph is about 440 modules and carries a sheet.
//
// The order the host sees is the same as before: the host-events subscription, then `ready`. Events
// that arrive before the page installed its bridge are held, then applied in order when
// `startHostEvents` takes the subscription (pageHost.ts).
import { createPageClient, type PageClient } from "../../pages/shared/pageClient";

/// `cmux.agent.host.events` (pageHost.ts `HOST_EVENTS`), kept here so this module does not load
/// pageHost's graph.
const HOST_EVENTS = "cmux.agent.host.events";
/// `ready` on the shared page host (pageHost.ts `agentPageOp`).
const HANDSHAKE_OP = "cmux.agent.handshake";

/// The early request, by the route that took it. `page`: the raw page call, whose `PageError`
/// pageHost maps as `callPageHost` does. `legacy`: the `agentSession` handler's `{ok, value}` reply.
export type EarlyHandshake =
  | {
      route: "page";
      client: PageClient;
      reply: Promise<unknown>;
      startedAt: number;
    }
  | { route: "legacy"; reply: Promise<unknown>; startedAt: number };
// `startedAt` is `Date.now()` time, as the launch marks are (perf.ts `markLaunch`).

type HeldEvents = {
  client: PageClient;
  subscription: Promise<() => void>;
  held: unknown[];
  sink?: (event: never) => void;
};

let early: EarlyHandshake | undefined;
let pageClient: PageClient | undefined;
let events: HeldEvents | undefined;

type LegacyHandler = { postMessage(body: unknown): unknown };

function legacyHandler(): LegacyHandler | undefined {
  const handler = (globalThis as { webkit?: { messageHandlers?: Record<string, unknown> } }).webkit?.messageHandlers
    ?.agentSession as LegacyHandler | undefined;
  return handler && typeof handler.postMessage === "function" ? handler : undefined;
}

/// Asks the host for the pane's handshake now. Does nothing where the page answers its own `ready`
/// (`cmuxAcpmuxActions`: the gallery, the mock dev page) or no host is there yet (the browser pane
/// installs its host in `main.tsx`'s body): the pane's effect asks then, as before.
export function startEarlyHandshake(now = Date.now()): void {
  if (early || typeof window === "undefined") return;
  if ((window as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions?.ready) return;
  const client = createPageClient();
  if (client) {
    pageClient = client;
    // Subscribed first, as the pane's effect did (`startHostEvents` before `connectHost`), so an
    // event the host sends while answering `ready` (the tab row offered again) reaches the page.
    const held: HeldEvents = {
      client,
      held: [],
      subscription: Promise.resolve(() => undefined),
    };
    held.subscription = client.subscribe(HOST_EVENTS, (event) => {
      if (held.sink) held.sink(event as never);
      else held.held.push(event);
    });
    held.subscription.catch(() => undefined);
    events = held;
    const reply = client.call(HANDSHAKE_OP, {});
    reply.catch(() => undefined);
    early = { route: "page", client, reply, startedAt: now };
    return;
  }
  const handler = legacyHandler();
  if (!handler) return;
  const reply = Promise.resolve(
    handler.postMessage({
      id: crypto.randomUUID(),
      method: "ready",
      params: {},
    }),
  );
  reply.catch(() => undefined);
  early = { route: "legacy", reply, startedAt: now };
}

/// The early handshake, once: the pane's first `connectHost` awaits it instead of asking again.
/// Undefined when none was asked, or it was taken (a retry or reconnect asks the host itself).
export function takeEarlyHandshake(): EarlyHandshake | undefined {
  const taken = early;
  early = undefined;
  return taken;
}

/// The page client this module made, once, for `pageHostClient` to keep (one client per page: it
/// owns the page's receive hook).
export function adoptEarlyPageClient(): PageClient | undefined {
  const client = pageClient;
  pageClient = undefined;
  return client;
}

/// The host-events subscription asked before the bridge existed, once, for `startHostEvents`: the
/// events it held are applied now in order, and later ones go straight to `apply`.
export function takeEarlyHostEvents<E>(client: PageClient, apply: (event: E) => void): Promise<() => void> | undefined {
  const held = events;
  if (!held || held.client !== client) return undefined;
  events = undefined;
  held.sink = apply as (event: never) => void;
  for (const event of held.held.splice(0)) apply(event as E);
  return held.subscription;
}

/// Tests: forget the early handshake, its client and held events, as a new page starts.
export function resetEarlyHandshakeForTests(): void {
  early = undefined;
  pageClient = undefined;
  events = undefined;
}

startEarlyHandshake();
