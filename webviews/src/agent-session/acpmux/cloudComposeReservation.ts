import type { SwitchClock } from "./harnessSwitch";
import { RELEASE_AFTER_MS } from "./newChatPrewarm";

/// How long a Send waits for its compose reservation before it starts without it. The reserve is a
/// speculative warm: the platform may hold it for up to two minutes (Rust's 120 s call, 125 s for the
/// process), and a Send that waited that long showed nothing but the start, with the composer locked
/// (Leo, 2026-11-09: "it seems like it's not actually properly starting").
export const RESERVATION_SEND_WAIT_MS = 3000;

type Native = (method: string, params: Record<string, unknown>) => Promise<unknown>;
type Attempt = {
  key: string;
  ready: Promise<boolean>;
  transferred: boolean;
  abandoned: boolean;
  released: boolean;
};

/// One speculative machine per compose. The platform owns its expiry; the page has no refresh
/// loop. Leaving Cloud or clearing the prompt gives an unused machine back sooner. Send takes
/// ownership before the host can close this page, and retries keep the same reservation key.
export class CloudComposeReservation {
  private attempt?: Attempt;
  private cancelRelease?: () => void;

  constructor(
    private readonly call: Native,
    private readonly clock: SwitchClock,
    private readonly newKey: () => string = () => crypto.randomUUID(),
  ) {}

  selected(): void {
    this.stopRelease();
    if (this.attempt && !this.attempt.abandoned && !this.attempt.released) return;
    this.attempt = undefined;
    const attempt: Attempt = {
      key: this.newKey(),
      ready: Promise.resolve(false),
      transferred: false,
      abandoned: false,
      released: false,
    };
    this.attempt = attempt;
    attempt.ready = Promise.resolve()
      .then(() => this.call("cloud.reserve", { composeKey: attempt.key }))
      .then(
        () => true,
        () => false,
      )
      .then((ready) => {
        // A close/switch can race the allocation. Release after it settles so a late successful
        // create cannot arrive after the page's DELETE and leak until expiry.
        if (attempt.abandoned && !attempt.transferred) this.release(attempt);
        return ready;
      });
  }

  typed(text: string): void {
    if (text.trim()) {
      this.selected();
    } else if (this.attempt && !this.attempt.transferred && !this.cancelRelease) {
      this.cancelRelease = this.clock.schedule(() => {
        this.cancelRelease = undefined;
        this.abandon();
      }, RELEASE_AFTER_MS);
    }
  }

  /// Called only for an accepted Send. The caller waits for ready() before asking the host to
  /// bind, so an immediate Return cannot race an allocation that is still in flight.
  handoff(environment?: string): string | undefined {
    this.stopRelease();
    // This compose warmed the default image. A later environment pick takes its ordinary,
    // configured create path rather than binding a machine from a different image.
    if (environment) {
      this.abandon();
      return undefined;
    }
    const attempt = this.attempt;
    if (!attempt || attempt.abandoned) return undefined;
    // A reservation goes with one Send only: the platform binds it to that Send's key, and another
    // Send naming it is refused (409 reservation.bound). A later Send gives it back instead: one the
    // first Send never bound (refused before its bind: a home folder, an attachment) is released,
    // and a bound one is refused there and stays that Send's. This Send goes without one.
    if (attempt.transferred) {
      this.attempt = undefined;
      // After its reserve settled: a DELETE ahead of the create would leak the machine to expiry.
      void attempt.ready.then(() => this.release(attempt));
      return undefined;
    }
    attempt.transferred = true;
    return attempt.key;
  }

  async ready(key: string): Promise<boolean> {
    const attempt = this.attempt;
    return attempt?.key === key ? attempt.ready : false;
  }

  /// The handed-off reservation's answer for a Send, or false once `waitMs` passed. A reserve that
  /// answers later is this compose's no longer: it is released when it settles (never before: a
  /// DELETE ahead of its create would leak the machine until expiry), and never handed off again.
  async readyForSend(key: string, waitMs: number = RESERVATION_SEND_WAIT_MS): Promise<boolean> {
    const attempt = this.attempt;
    if (attempt?.key !== key || attempt.abandoned) return false;
    let cancel: (() => void) | undefined;
    const late = new Promise<"late">((resolve) => {
      cancel = this.clock.schedule(() => resolve("late"), waitMs);
    });
    const answer = await Promise.race([attempt.ready, late]);
    cancel?.();
    if (answer !== "late") return answer;
    attempt.transferred = false;
    attempt.abandoned = true;
    void attempt.ready.then(() => this.release(attempt));
    return false;
  }

  abandon(): void {
    this.stopRelease();
    const attempt = this.attempt;
    if (!attempt || attempt.transferred || attempt.abandoned) return;
    attempt.abandoned = true;
    void attempt.ready.then(() => this.release(attempt));
  }

  reset(): void {
    this.abandon();
    this.attempt = undefined;
  }

  private stopRelease(): void {
    this.cancelRelease?.();
    this.cancelRelease = undefined;
  }

  private release(attempt: Attempt): void {
    if (attempt.released) return;
    attempt.released = true;
    void this.call("cloud.releaseReservation", { composeKey: attempt.key }).catch(() => undefined);
  }
}

/// Keep oneCloudStart's pending-send guard while waiting for the speculative request. A failed or
/// slow prewarm falls back to the ordinary Send path; it never prevents sending a chat, nor holds it
/// for longer than RESERVATION_SEND_WAIT_MS.
export function reservedCloudCall(
  call: Native,
  reservation: CloudComposeReservation,
): (method: string, params?: Record<string, unknown>) => Promise<unknown> {
  return async (method, params = {}) => {
    const reservationKey = params.reservationKey;
    if (method === "cloud.startChat" && typeof reservationKey === "string" && typeof params.key === "string") {
      // Reserve the Send gesture before waiting for the platform lease. Native's hand-off can
      // then redeem this ticket after a slow reserve instead of trying to consume the 30-second
      // live gesture at the end of the wait.
      const ticket = await call("transport.gesture", {
        intent: { method: "cloud.startChat", params: { key: params.key } },
      })
        .then((reply) => (reply as { ticket?: unknown } | undefined)?.ticket)
        .catch(() => undefined);
      // A reserve slower than RESERVATION_SEND_WAIT_MS no longer holds the Send: it goes as an
      // ordinary one, and the late reservation is released (readyForSend).
      if (!(await reservation.readyForSend(reservationKey))) {
        const { reservationKey: _reservationKey, gestureTicket: _gestureTicket, ...ordinary } = params;
        // The native gesture was already consumed to obtain this ticket. Keep it on the
        // ordinary Send fallback so a failed or unavailable reservation cannot turn into a
        // second gesture check (and gesture_required) in native hand-off.
        return call(method, {
          ...ordinary,
          ...(typeof ticket === "string" ? { gestureTicket: ticket } : {}),
        });
      }
      return call(method, {
        ...params,
        ...(typeof ticket === "string" ? { gestureTicket: ticket } : {}),
      });
    }
    return call(method, params);
  };
}
