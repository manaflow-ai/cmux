import type { GuestPrompts } from "../agent-session/guest/guestPrompts";
import { ChiefUnavailable, InvalidClientMessageId, type ChiefApi } from "./api";
import { ChiefAccessError, ExpiredSession } from "./wire";

type Clock = {
  now(): number;
  set(run: () => void, ms: number): unknown;
  clear(timer: unknown): void;
};
const clock: Clock = {
  now: Date.now,
  set: (run, ms) => setTimeout(run, ms),
  clear: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};

/** HTTP owns one active request, including retries. Wire reconnects only resume this same queue;
 * they never enqueue another copy of a request that is still awaiting its HTTP receipt. */
export class ChiefOutbox {
  private online = false;
  private stopped = false;
  private active?: AbortController;
  private timer?: unknown;
  private retry?: { id: string; attempt: number; at: number };

  constructor(
    private readonly prompts: GuestPrompts,
    private readonly api: Pick<ChiefApi, "send">,
    private readonly terminal: (state: "expired" | "inaccessible") => void,
    private readonly time: Clock = clock,
  ) {}

  connected(): void {
    if (this.stopped) return;
    this.online = true;
    this.pump();
  }

  disconnected(): void {
    this.online = false;
    this.cancelTimer();
  }

  queued(): void {
    this.pump();
  }

  accepted(clientId: string): void {
    if (this.stopped) return;
    this.prompts.update({ client_id: clientId, state: "approved" });
    if (this.retry?.id === clientId) this.retry = undefined;
    this.cancelTimer();
    this.pump();
  }

  stop(): void {
    this.stopped = true;
    this.disconnected();
    this.active?.abort();
    this.retry = undefined;
  }

  private cancelTimer(): void {
    if (this.timer !== undefined) this.time.clear(this.timer);
    this.timer = undefined;
  }

  private pump(): void {
    if (this.stopped || !this.online || this.active || this.timer !== undefined) return;
    const prompt = this.prompts.unsent()[0];
    if (!prompt) return;
    if (this.retry?.id !== prompt.clientId) this.retry = undefined;
    const wait = (this.retry?.at ?? 0) - this.time.now();
    if (wait > 0) {
      this.timer = this.time.set(() => {
        this.timer = undefined;
        this.pump();
      }, wait);
      return;
    }
    const request = new AbortController();
    this.active = request;
    void this.api
      .send(prompt.text, prompt.clientId, request.signal)
      .then(
        () => {
          if (!this.stopped) this.accepted(prompt.clientId);
        },
        (error: unknown) => {
          if (this.stopped) return;
          if (error instanceof ExpiredSession || error instanceof ChiefAccessError) {
            this.stop();
            this.terminal(error instanceof ExpiredSession ? "expired" : "inaccessible");
            // A wire receipt may win the race against a late HTTP/network failure.
          } else if (this.prompts.list().find((entry) => entry.clientId === prompt.clientId)?.state !== "sending") {
            return;
          } else if (
            !(error instanceof InvalidClientMessageId) &&
            (error instanceof ChiefUnavailable ||
              error instanceof TypeError ||
              (error instanceof DOMException && error.name === "TimeoutError"))
          ) {
            const attempt = (this.retry?.attempt ?? 0) + 1;
            this.retry = {
              id: prompt.clientId,
              attempt,
              at: this.time.now() + Math.min(30_000, 1_000 * 2 ** Math.min(attempt - 1, 5)),
            };
          } else this.prompts.update({ client_id: prompt.clientId, state: "refused" });
        },
      )
      .finally(() => {
        if (this.active === request) this.active = undefined;
        this.pump();
      });
  }
}
