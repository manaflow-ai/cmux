// A send made while acpmux starts, restarts or reconnects is held and sent once it answers, never
// failed at once (Leo, 2026-11-06: "your sends are getting busted intermittently as things load").
// The prompt stays in the composer, which says "Sending when ready", and its row (if it has one)
// keeps its clock. It waits as long as acpmux is away (a restart, its machine rebooting), with no
// deadline that turns it into "Not sent" and Retry (Leo, 2026-11-12: "try what? no, it should just
// automatically do stuff"); it stops only when the send is no longer wanted (`stop`).
import { hostIsReconnecting, hostRefusedTooLarge, nextRetryDelay } from "./hostRetry";

/// The first wait before a held send asks again; each next wait doubles up to 2 s (`nextRetryDelay`).
export const SEND_RETRY_FIRST_MS = 250;

/// A failed send that goes again by itself (direct.ts `resendItself`) first waits this long, then
/// twice as long each time, up to SELF_RESEND_MAX_MS, with no last try.
export const SELF_RESEND_FIRST_MS = 1000;
export const SELF_RESEND_MAX_MS = 30_000;

/// Whether a failed send may go again on its own: the pane had no connection to acpmux, so the
/// frame never left it (`native.not_connected`), and acpmux comes back by itself. Only such a frame
/// goes again: a frame that reached the app spent the send's gesture ticket (the native relay
/// redeems it before forwarding), so asking again with it would only be refused, and a
/// `native.timed_out` keeps its own way back (the relay journal, `lostPrompt`). A send's own
/// refusals (a selection that moved, a cancelled start) are plain errors and never go again; nor
/// does a prompt acpmux took, or one already shown as a failed row.
export function sendWaitsForHost(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const fields = error as { code?: unknown; taken?: unknown; failedRow?: unknown };
  if (fields.taken === true || fields.failedRow !== undefined) return false;
  if (hostRefusedTooLarge(error)) return false;
  return fields.code === "native.not_connected" && hostIsReconnecting(error);
}

export type HostWait = {
  /// How long the send may wait for the host, from its first try. Default: no end.
  deadlineMs?: number;
  /// The send is no longer wanted (its chat moved, its client closed, acpmux took it): stop asking.
  stop?: () => boolean;
  /// Called before each wait: the send is held for the host.
  waiting?: () => void;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
};

/// Runs `attempt` and, while it fails for a reason the host clears by itself, runs it again after a
/// backoff (250 ms doubling to 2 s). It stops, rethrowing the last failure, at the first failure the
/// host does not clear, when `stop()` says the send is no longer wanted (its chat moved, its client
/// closed), or when the next try would start past `deadlineMs`, if one is given. Each try only
/// looks for a connection (`native.not_connected` never left the pane), so one every 2 s costs
/// nothing while a machine reboots.
export async function untilHostAnswers<T>(attempt: () => Promise<T>, wait: HostWait = {}): Promise<T> {
  const now = wait.now ?? Date.now;
  const sleep = wait.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const deadline = now() + (wait.deadlineMs ?? Number.POSITIVE_INFINITY);
  let delay = SEND_RETRY_FIRST_MS;
  for (;;) {
    try {
      return await attempt();
    } catch (error) {
      if (!sendWaitsForHost(error) || wait.stop?.() || now() + delay > deadline) throw error;
      wait.waiting?.();
      await sleep(delay);
      // A timer that fired late (a busy or sleeping Mac) never starts a try past the deadline.
      if (wait.stop?.() || now() > deadline) throw error;
      delay = nextRetryDelay(delay, true);
    }
  }
}

/// The stop for a held start (`ensureSession` retried while acpmux comes back): it belongs to the
/// chat selected at the send. Once the client closed, or another chat is selected (a new selection
/// generation), the next try would send the prompt into that chat, so the wait stops and the send
/// fails as before. A start's own successful selection ends the wait with its answer, never here.
export function heldStartStop(client: {
  readonly isClosed: boolean;
  readonly trustGeneration: number;
  readonly selectedSession: string | undefined;
}): () => boolean {
  const generation = client.trustGeneration;
  const sessionId = client.selectedSession;
  return () => client.isClosed || client.trustGeneration !== generation || client.selectedSession !== sessionId;
}

/// How many of this page's sends are held for the host now: the composer says "Sending when ready"
/// while any is (Composer.tsx). A page draws one chat's composer, so one count serves it.
let held = 0;
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((listener) => listener());

export const sendsHeldForHost = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  get(): boolean {
    return held > 0;
  },
  /// Counts one held send; the returned release (idempotent) ends it.
  hold(): () => void {
    held += 1;
    if (held === 1) changed();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      held -= 1;
      if (held === 0) changed();
    };
  },
};

/// The page's chat client went with its connection (pane/paneSnapshot.ts `onLost`) and the pane is
/// looking for the next one: the page's actions (`window.cmuxAcpmuxActions`) are gone meanwhile.
/// A `chat.send` made then went to the app, which has no such action, and its refusal put the
/// prompt back in the composer, unsent, for the person to send again. Now it waits for the next
/// client (`whenPageClientBack`) and goes on it once, under the id that client gives it, while the
/// composer says "Sending when ready" (`sendsHeldForHost`). The pane never gives up on its own
/// agent service, so the wait has no deadline; it ends unsent only when the pane itself goes.
let clientAway = false;
const clientWaiters = new Set<{ back: () => void; gone: (error: Error) => void }>();

export const pageClientLink = {
  /// The page's client was lost: sends wait for the next one.
  lost(): void {
    clientAway = true;
  },
  /// A client connected and installed the page's actions: the sends that waited go now.
  back(): void {
    clientAway = false;
    const waiting = [...clientWaiters];
    clientWaiters.clear();
    for (const waiter of waiting) waiter.back();
  },
  /// The pane went (unmounted): no client comes, so what waited fails and goes back to its composer.
  ended(): void {
    clientAway = false;
    const waiting = [...clientWaiters];
    clientWaiters.clear();
    // l10n-allow: never shown; the sender reads only that it failed and puts the prompt back.
    for (const waiter of waiting) waiter.gone(new Error("pane closed"));
  },
  away(): boolean {
    return clientAway;
  },
};

/// Runs `send` now, or, while the page's client is away (`pageClientLink`), once the next one is
/// back. It is held meanwhile, as any send waiting for acpmux is (`sendsHeldForHost`).
export async function whenPageClientBack<T>(send: () => Promise<T>): Promise<T> {
  if (!clientAway) return send();
  const unhold = sendsHeldForHost.hold();
  try {
    await new Promise<void>((back, gone) => clientWaiters.add({ back, gone }));
  } finally {
    unhold();
  }
  return send();
}

/// The prompts sent straight to the chat that acpmux has not taken (or refused) yet, and the wait for
/// the last of them: a prompt sent meanwhile goes after it, never before (`sendInTurn`). `noAcpmux`:
/// the host answered that this page has no acpmux to reach (a preview host, the gallery): no
/// `chat.send` will ever come, so a send is not "made while the chat loads" and never waits for one
/// in the pane's queue; the composer keeps it, as before (`untilAcpmuxTakesSends`).
export const paneSends: { direct: number; inFlight: Promise<void>; noAcpmux: boolean } = {
  direct: 0,
  inFlight: Promise.resolve(),
  noAcpmux: false,
};

/// The sends waiting for this page to connect to acpmux (`window.cmuxAcpmuxActions` has no
/// `chat.send` yet: the chat still loads, or acpmux restarts). Each goes, in its turn, the moment the
/// page connects (`acpmuxSendsReady`), never refused and never left in the composer (Leo,
/// 2026-11-17: "I CAN'T EVEN SEND A MESSAGE WHILE THE THING LOADS ... JUST MAKE IT LOOK LIKE IT'S
/// SENT OR JUST SEND IT"). A wait ends with the connection only: each one belongs to a send the
/// person made, which its row draws and its Remove withdraws.
const connectWaiters = new Set<() => void>();

/// Resolves once acpmux takes prompts on this page: at once when it does now.
export function untilAcpmuxTakesSends(page: { cmuxAcpmuxActions?: Record<string, unknown> } = window): Promise<void> {
  if (page.cmuxAcpmuxActions?.["chat.send"]) return Promise.resolve();
  return new Promise((resolve) => {
    const ready = () => {
      if (!page.cmuxAcpmuxActions?.["chat.send"]) return;
      connectWaiters.delete(ready);
      resolve();
    };
    connectWaiters.add(ready);
  });
}

/// The page installed (or replaced) its acpmux actions: the sends waiting for them go.
export function acpmuxSendsReady(): void {
  for (const ready of [...connectWaiters]) ready();
}
