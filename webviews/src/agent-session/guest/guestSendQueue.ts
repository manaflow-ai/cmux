// One paced outbound path for a guest's fresh messages and replay after reconnect.
// The room accepts two prompt frames/second, burst two; sending a saved backlog at once
// made the third and later messages permanently refused. Keep each client's original id,
// and retry only a temporary rate refusal, so acpmux's deduplication still owns execution.
import type { GuestPromptState } from "./shareSocket";
import { type GuestPrompt, type GuestPrompts } from "./guestPrompts";

export const GUEST_PROMPT_GAP_MS = 600;
export const GUEST_PROMPT_RETRY_MS = 1_200;

export type GuestSendTimers = {
  now: () => number;
  set: (run: () => void, ms: number) => unknown;
  clear: (timer: unknown) => void;
};

const timers: GuestSendTimers = {
  now: () => performance.now(),
  set: (run, ms) => setTimeout(run, ms),
  clear: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};

const decided = (state: GuestPrompt["state"]) =>
  state === "approved" || state === "declined" || state === "removed" || state === "refused";

/** One guest tab's outbox. A socket snapshot proves it can send; a close stops its timer. */
export class GuestSendQueue {
  private connected = false;
  private stopped = false;
  private timer?: unknown;
  private nextAt = 0;
  private readonly sent = new Set<string>();
  private readonly retryAt = new Map<string, number>();

  constructor(
    private readonly prompts: GuestPrompts,
    private readonly send: (prompt: GuestPrompt) => boolean,
    private readonly clock: GuestSendTimers = timers,
  ) {}

  /** The current socket is synced. Fold server decisions before retrying unacknowledged messages. */
  snapshot(states: readonly GuestPromptState[]): void {
    if (this.stopped) return;
    this.disconnected();
    for (const state of states) this.status(state);
    this.sent.clear();
    this.connected = true;
    this.pump();
  }

  /** The composer recorded another message. Send it through the same budget as replayed ones. */
  queued(): void {
    this.pump();
  }

  /** A refusal caused by the room's burst limit is retryable, with the same client id. */
  status(state: GuestPromptState): void {
    if (this.stopped) return;
    const prompt = this.prompts.list().find((entry) => entry.clientId === state.client_id);
    if (!prompt) return;
    if (state.state === "refused" && state.reason === "share.rate_limited") {
      // An earlier duplicate's late refusal must never undo a prompt already held or decided.
      if (prompt.state !== "sending") return;
      this.sent.delete(prompt.clientId);
      this.retryAt.set(prompt.clientId, this.clock.now() + GUEST_PROMPT_RETRY_MS);
      this.cancelTimer();
      this.pump();
      return;
    }
    this.sent.delete(prompt.clientId);
    this.retryAt.delete(prompt.clientId);
    this.prompts.update(state);
    this.pump();
  }

  /** The socket is down; the next snapshot will replay the same unsent ids. */
  disconnected(): void {
    this.connected = false;
    this.cancelTimer();
  }

  stop(): void {
    this.stopped = true;
    this.disconnected();
    this.sent.clear();
    this.retryAt.clear();
  }

  private cancelTimer(): void {
    if (this.timer !== undefined) this.clock.clear(this.timer);
    this.timer = undefined;
  }

  private pump(): void {
    if (!this.connected || this.stopped || this.timer !== undefined) return;
    const next = this.prompts.unsent().find((prompt) => !this.sent.has(prompt.clientId));
    if (!next) return;
    const now = this.clock.now();
    const wait = Math.max(0, this.nextAt - now, (this.retryAt.get(next.clientId) ?? 0) - now);
    if (wait > 0) {
      this.timer = this.clock.set(() => {
        this.timer = undefined;
        this.pump();
      }, wait);
      return;
    }
    if (!this.send(next)) {
      this.disconnected();
      return;
    }
    this.sent.add(next.clientId);
    this.retryAt.delete(next.clientId);
    this.nextAt = now + GUEST_PROMPT_GAP_MS;
    this.pump();
  }
}
