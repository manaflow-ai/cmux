// A send made while acpmux starts, restarts or reconnects is held and sent once it answers, never
// failed at once (Leo, 2026-11-06: "your sends are getting busted intermittently as things load").
// The prompt stays where it was sent (its row, or the composer of a chat not started yet), and
// nothing says it waits until it has waited past SEND_LATE_MS. It waits as long as acpmux is away (a restart, its machine rebooting), with no
// deadline that turns it into "Not sent" and Retry (Leo, 2026-11-12: "try what? no, it should just
// automatically do stuff"); it stops only when the send is no longer wanted (`stop`).
import { useEffect, useState, useSyncExternalStore } from "react";
import { PEER_LINK_DEADLINE_MS } from "./hostLine";
import { hostIsReconnecting, hostRefusedTooLarge, nextRetryDelay } from "./hostRetry";

/// The first wait before a held send asks again; each next wait doubles up to 2 s (`nextRetryDelay`).
export const SEND_RETRY_FIRST_MS = 250;

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

/// How long a send may wait for its agent's machine (or this Mac's acpmux) before anything says so.
/// Until then nothing at all is drawn for the wait, however the link is doing: no spinner, no
/// "Sending when ready", no "Reconnecting…" (Leo, 2026-11-22: "i dont wanna see connecting to
/// cosmic-gray... with the spinner, i want it to just work ... if we're slow, STOP FUCKING SHOWING
/// ME SO MUCH FUCKING BULLSHIT"). Past it the send says once, quietly, on its own message (or under
/// the prompt of a chat not started yet) that it has not gone yet and goes when the machine is back:
/// conversation/PromptDelivery.tsx `pendingLabel`. Two minutes is the pane's bound for a machine that
/// is really gone, not slow (hostLine.ts `PEER_LINK_DEADLINE_MS`); acpmux's own redial heals a drop
/// in under 3 s (afterDelay.ts `LINK_DOWN_SAID_MS`).
export const SEND_LATE_MS = PEER_LINK_DEADLINE_MS;

/// How many of this page's sends are held for the host now, and since when: the composer says the
/// prompt has not gone yet once one has waited past SEND_LATE_MS (Composer.tsx `useHeldForHostLate`).
/// A page draws one chat's composer, so one count serves it.
let held = 0;
let heldSince: number | undefined;
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
  /// When the first send still held began waiting (`Date.now()` time), or undefined when none waits.
  since(): number | undefined {
    return heldSince;
  },
  /// Counts one held send; the returned release (idempotent) ends it.
  hold(): () => void {
    held += 1;
    if (held === 1) {
      heldSince = Date.now();
      changed();
    }
    let released = false;
    return () => {
      if (released) return;
      released = true;
      held -= 1;
      if (held === 0) {
        heldSince = undefined;
        changed();
      }
    };
  },
};

/// True once a send of this page has waited for the host past SEND_LATE_MS; false at once when none
/// waits. One timer per wait; nothing runs while no send waits.
export function useHeldForHostLate(ms: number = SEND_LATE_MS): boolean {
  const waiting = useSyncExternalStore(sendsHeldForHost.subscribe, sendsHeldForHost.get);
  const since = waiting ? sendsHeldForHost.since() : undefined;
  return usePastSince(since, ms);
}

/// True once `ms` has passed since `since` (`Date.now()` time); false while `since` is undefined.
export function usePastSince(since: number | undefined, ms: number): boolean {
  // The `since` the flag was set for: a new wait never reads the last one's answer.
  const [pastFor, setPastFor] = useState<number | undefined>(() =>
    since !== undefined && Date.now() - since >= ms ? since : undefined,
  );
  useEffect(() => {
    if (since === undefined) return;
    const left = ms - (Date.now() - since);
    if (left <= 0) {
      setPastFor(since);
      return;
    }
    const timer = setTimeout(() => setPastFor(since), left);
    return () => clearTimeout(timer);
  }, [since, ms]);
  return since !== undefined && pastFor === since;
}
