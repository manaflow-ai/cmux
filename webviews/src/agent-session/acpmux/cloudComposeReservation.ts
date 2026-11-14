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
  /// When the last `cloud.reserve` for this key went out (the first, a renewal or a retry).
  reservedAt: number;
  /// The last intent (Cloud picked, a character typed) this compose saw.
  intentAt: number;
  /// Reserves for this key that failed in a row (none: the last one answered, or is out).
  failures: number;
};

/// While the person still means to send (Cloud picked, typing), the same compose key is reserved
/// again at most this often: the platform renews the hold (cmux-platform RESERVATION_HOLD_MS), so a
/// prompt written over several minutes still finds its machine resumed and its login copied at Send
/// (Leo, 2026-11-09: "pre-setting up stuff as a user selected cloud and was starting to type ... at
/// least frontload the stuff that we can check earlier").
export const RESERVATION_RENEW_MS = 60_000;
/// A reserve that failed (a Cloud pick the page made itself, with no gesture, such as a remembered
/// Cloud target on load; the platform unavailable) is tried again on the next intent, with the
/// same key, after this gap, doubled for each failure in a row up to RESERVATION_RENEW_MS.
export const RESERVATION_RETRY_MS = 2_000;
/// No intent for this long and nothing sent: the compose gives its machine back. The platform's
/// hold ends at the same bound after its last renewal (RESERVATION_HOLD_MS), so a page that went
/// away without releasing costs no more.
export const RESERVATION_IDLE_RELEASE_MS = 10 * 60_000;

/// One speculative machine per compose. The platform owns its expiry; the page renews its hold
/// only on the person's intent and releases it after RESERVATION_IDLE_RELEASE_MS without one.
/// Leaving Cloud or clearing the prompt gives an unused machine back sooner. Send takes
/// ownership before the host can close this page, and retries keep the same reservation key.
export class CloudComposeReservation {
  private attempt?: Attempt;
  private cancelRelease?: () => void;
  private cancelIdle?: () => void;

  constructor(
    private readonly call: Native,
    private readonly clock: SwitchClock,
    private readonly newKey: () => string = () => crypto.randomUUID(),
  ) {}

  selected(): void {
    this.stopRelease();
    const now = this.clock.now();
    const live = this.attempt;
    if (live && !live.abandoned && !live.released) {
      live.intentAt = now;
      // Renew (or retry) with the same key: idempotent at the platform, never a second machine.
      const gap = live.failures
        ? Math.min(RESERVATION_RENEW_MS, RESERVATION_RETRY_MS * 2 ** (live.failures - 1))
        : RESERVATION_RENEW_MS;
      if (!live.transferred && now - live.reservedAt >= gap) this.reserve(live, live.ready);
      return;
    }
    this.attempt = undefined;
    const attempt: Attempt = {
      key: this.newKey(),
      ready: Promise.resolve(false),
      transferred: false,
      abandoned: false,
      released: false,
      reservedAt: now,
      intentAt: now,
      failures: 0,
    };
    this.attempt = attempt;
    this.reserve(attempt, Promise.resolve());
    this.watchIdle(attempt, RESERVATION_IDLE_RELEASE_MS);
  }

  /// One `cloud.reserve` for `attempt`'s key, after `after` (the call before it for the same key)
  /// settled, so the native pane sees one at a time. `ready` is this call's answer: a renewal that
  /// failed leaves the native pane no longer owning the key, so the Send must not name it.
  private reserve(attempt: Attempt, after: Promise<unknown>): void {
    attempt.reservedAt = this.clock.now();
    attempt.ready = after
      .then(() => this.call("cloud.reserve", { composeKey: attempt.key }))
      .then(
        () => true,
        () => false,
      )
      .then((ready) => {
        attempt.failures = ready ? 0 : attempt.failures + 1;
        // A close/switch can race the allocation. Release after it settles so a late successful
        // create cannot arrive after the page's DELETE and leak until expiry.
        if (attempt.abandoned && !attempt.transferred) this.release(attempt);
        return ready;
      });
  }

  /// Releases `attempt` once RESERVATION_IDLE_RELEASE_MS passed since its last intent with no Send.
  /// One timer per compose, moved on only when it fires, so a keystroke schedules nothing.
  private watchIdle(attempt: Attempt, ms: number): void {
    this.stopIdle();
    this.cancelIdle = this.clock.schedule(() => {
      this.cancelIdle = undefined;
      if (this.attempt !== attempt || attempt.transferred || attempt.abandoned) return;
      const left = attempt.intentAt + RESERVATION_IDLE_RELEASE_MS - this.clock.now();
      if (left > 0) this.watchIdle(attempt, left);
      else this.abandon();
    }, ms);
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
    this.stopIdle();
    // This compose warmed the default image. A later environment pick takes its ordinary,
    // configured create path rather than binding a machine from a different image.
    if (environment) {
      this.abandon();
      return undefined;
    }
    const attempt = this.attempt;
    if (!attempt || attempt.abandoned) return undefined;
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

  /// The Send that took reservation `key` was refused before the host bound it (a folder too big to copy,
  /// `cloud_folder_too_big`): nothing will claim it, so it is given back now, and the next Send starts cold
  /// or a new compose reserves again.
  returned(key: string): void {
    const attempt = this.attempt;
    if (attempt?.key !== key || !attempt.transferred) return;
    attempt.transferred = false;
    attempt.abandoned = true;
    void attempt.ready.then(() => this.release(attempt));
  }

  abandon(): void {
    this.stopRelease();
    this.stopIdle();
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

  private stopIdle(): void {
    this.cancelIdle?.();
    this.cancelIdle = undefined;
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
