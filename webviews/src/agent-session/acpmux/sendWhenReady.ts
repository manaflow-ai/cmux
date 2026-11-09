// A send made while acpmux starts, restarts or reconnects is held and sent once it answers, never
// failed at once (Leo, 2026-11-06: "your sends are getting busted intermittently as things load").
// The prompt stays in the composer, which says "Sending when ready", and its row (if it has one)
// keeps its clock. Only a wait past the host's deadline (hostRetry.ts `HOST_ERROR_DEADLINE_MS`, the
// same 25 s after which the pane says the host is down) fails the send, as a row with Retry.
import { HOST_ERROR_DEADLINE_MS, hostIsReconnecting, hostRefusedTooLarge, nextRetryDelay } from "./hostRetry";

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
  /// How long the send may wait for the host, from its first try. Default `HOST_ERROR_DEADLINE_MS`.
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
/// host does not clear, when `stop()` says the send is no longer wanted, or when the next try would
/// start past the deadline: at most about 16 tries in 25 s, never a loop without an end.
export async function untilHostAnswers<T>(attempt: () => Promise<T>, wait: HostWait = {}): Promise<T> {
  const now = wait.now ?? Date.now;
  const sleep = wait.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const deadline = now() + (wait.deadlineMs ?? HOST_ERROR_DEADLINE_MS);
  let delay = SEND_RETRY_FIRST_MS;
  for (;;) {
    try {
      return await attempt();
    } catch (error) {
      if (!sendWaitsForHost(error) || wait.stop?.() || now() + delay > deadline) throw error;
      wait.waiting?.();
      await sleep(delay);
      if (wait.stop?.()) throw error;
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
