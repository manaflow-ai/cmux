/**
 * Provider create admission: at most `cap` provider creates (`POST /v5/vms`) in flight per environment, the rest
 * queued first come, first served, for no longer than the caller can wait.
 *
 * Why (staging, 2026-11-27): when many creates reached the provider within a second or two, it answered the first 3 to
 * 8 and held the rest until our 120 s create timeout, with nothing made (54 of 162 creates in three windows). With at
 * most 3 in flight when a create arrived, no burst create hung. A create that waits here a few seconds and then gets
 * an answer beats one that is sent at once and hangs for 120 s; a create that cannot get a slot within its budget is
 * refused at once (a retryable 503 the platform retries with the same key) instead of hanging.
 *
 * One queue serves the whole environment: it lives in one Durable Object (TENANT_LIMITS under a name no tenant id can
 * take, `PROVIDER_CREATE_QUEUE_NAME`), which runs one call at a time. Every decision is made in one synchronous step
 * against the slots held at that moment (no version compare, handbook `burst-admitted-one-per-round.md`), so N
 * creates arriving together are each admitted, queued or refused on their first call.
 *
 * Slots are written through to storage, since the object may be evicted while a create holds one, and each slot is a
 * lease: a Worker that dies mid-create gives its slot back once `leaseMs` passes. Waiters live in memory only; a
 * waiter's call is pending, which keeps the object alive, and a lost waiter (the object restarted) fails its RPC,
 * which the caller treats as "admission unavailable" and sends anyway.
 *
 * A background create (a spare the platform makes ahead of anyone asking, `x-cmux-create-priority: background`) waits
 * behind every person's create: it joins the queue after them, and background creates hold at most `cap - 1` slots, so
 * one slot is always left for a person. Staging, 2026-11-27 14:00-15:00Z: the platform's spare fills made 123 VMs
 * while 341 creates were admitted and 1089 of 1430 attempts were refused (queue_full or wait_expired); a person's or a
 * journey's create was refused behind spares no one was waiting on.
 */
import { Schema } from "effect";
import type { LedgerStorage } from "./storage.ts";

/** The Durable Object name of the environment's queue: the space keeps it out of every tenant id (`[A-Za-z0-9_-]+`). */
export const PROVIDER_CREATE_QUEUE_NAME = "provider creates";

/**
 * Creates in flight per environment, from staging 2026-11-27: the provider answered at least the first 3 of every
 * burst (3, 5 and 8 in three bursts) and hung the rest, and no create that arrived with 3 or fewer in flight hung in a
 * burst. Override with PROVIDER_CREATE_CONCURRENCY ("none" turns the queue off).
 */
export const DEFAULT_CREATE_CONCURRENCY = 3;

/**
 * The longest a create waits for a slot. cmux-platform waits 270 s for a create (CloudProvider CREATE_TIMEOUT_MS);
 * a create here may spend 120 s on the provider create and 120 s on a resize, and about 5 s on reads and records:
 * 270 - 120 - 120 - 5 = 25 s. Override with PROVIDER_CREATE_QUEUE_WAIT_MS.
 */
export const DEFAULT_CREATE_QUEUE_WAIT_MS = 25_000;

/** A slot outlives the provider create's own 120 s timeout plus its recovery read, then frees itself. */
export const CREATE_SLOT_LEASE_MS = 130_000;

/** The first hold estimate: the median staging create at 1 to 3 in flight (14.4 s). Learned from releases after. */
export const INITIAL_HOLD_MS = 14_000;

export interface CreateAdmissionSettings {
  readonly cap: number;
  readonly queueWaitMs: number;
  readonly leaseMs: number;
}

export const CreateAdmitted = Schema.Struct({
  admitted: Schema.Literal(true),
  waitedMs: Schema.Number,
  inFlight: Schema.Number,
  queued: Schema.Number,
});
export const CreateRefused = Schema.Struct({
  admitted: Schema.Literal(false),
  /** queue_full: the wait ahead was already past the budget; wait_expired: queued, and no slot came in time. */
  reason: Schema.Literal("queue_full", "wait_expired"),
  waitedMs: Schema.Number,
  inFlight: Schema.Number,
  queued: Schema.Number,
  /** The estimated wait for a slot when refused; the platform's own backoff decides when it comes back. */
  retryAfterMs: Schema.Number,
});
export const CreateAdmission = Schema.Union(CreateAdmitted, CreateRefused);
export type CreateAdmission = typeof CreateAdmission.Type;

const Slot = Schema.Struct({ startedMs: Schema.Number, untilMs: Schema.Number, background: Schema.optional(Schema.Boolean) });
const isSlot = Schema.is(Slot);
type Slot = typeof Slot.Type;
const PREFIX = "create-slot:";

export interface AdmissionClock {
  readonly now: () => number;
  /** Runs `run` after `ms`; the answer cancels it. */
  readonly after: (ms: number, run: () => void) => () => void;
}

export const systemClock: AdmissionClock = {
  now: () => Date.now(),
  after: (ms, run) => {
    const timer = setTimeout(run, Math.max(0, ms));
    return () => clearTimeout(timer);
  },
};

/** A slot write is ordered before the object's next answer (its output gate); a failed one resets the object. */
const quietly = (write: Promise<unknown>) => { write.catch(() => undefined); };

interface Waiter {
  readonly holder: string;
  readonly background: boolean;
  readonly arrivedMs: number;
  readonly settings: CreateAdmissionSettings;
  readonly answer: (outcome: CreateAdmission) => void;
  cancel: () => void;
}

export class CreateAdmissionQueue {
  private slots: Map<string, Slot> | null = null;
  private loading: Promise<Map<string, Slot>> | null = null;
  private readonly waiters: Array<Waiter> = [];
  private meanHoldMs = INITIAL_HOLD_MS;
  private cancelLeaseTimer: (() => void) | null = null;

  constructor(
    private readonly storage: LedgerStorage,
    private readonly clock: AdmissionClock = systemClock,
  ) {}

  /** Held slots and waiters right now (tests and logs). */
  get state(): { readonly inFlight: number; readonly queued: number; readonly meanHoldMs: number } {
    return { inFlight: this.slots?.size ?? 0, queued: this.waiters.length, meanHoldMs: this.meanHoldMs };
  }

  /**
   * A slot for `holder`, now or after a first-come wait, or a refusal: at once when the wait ahead is already past
   * `queueWaitMs`, else when that much time passes without a slot. A holder that already has a slot keeps it. A
   * `background` create waits behind every person's create and holds at most `cap - 1` slots with the other background
   * creates (`backgroundCap`).
   */
  async admit(holder: string, settings: CreateAdmissionSettings, background = false): Promise<CreateAdmission> {
    const slots = await this.load();
    // From here to the end of this step nothing awaits: the check and the take see the same slots.
    const now = this.clock.now();
    this.expire(slots, now);
    const held = slots.get(holder);
    if (held !== undefined) {
      this.take(slots, holder, held.startedMs, now, settings);
      return { admitted: true, waitedMs: 0, inFlight: slots.size, queued: this.waiters.length };
    }
    const ahead = background ? this.waiters.length : this.foregroundWaiting();
    if (ahead === 0 && slots.size < settings.cap && (!background || backgroundHeld(slots) < backgroundCap(settings.cap))) {
      this.take(slots, holder, now, now, settings, background);
      return { admitted: true, waitedMs: 0, inFlight: slots.size, queued: this.waiters.length };
    }
    const estimate = this.estimateMs(ahead + 1, slots, now, settings);
    if (estimate > settings.queueWaitMs) {
      return { admitted: false, reason: "queue_full", waitedMs: 0, inFlight: slots.size, queued: this.waiters.length, retryAfterMs: estimate };
    }
    return new Promise<CreateAdmission>((answer) => {
      const waiter: Waiter = { holder, background, arrivedMs: now, settings, answer, cancel: () => {} };
      waiter.cancel = this.clock.after(settings.queueWaitMs, () => {
        const index = this.waiters.indexOf(waiter);
        if (index < 0) return;
        this.waiters.splice(index, 1);
        const at = this.clock.now();
        answer({
          admitted: false, reason: "wait_expired", waitedMs: at - now, inFlight: slots.size, queued: this.waiters.length,
          retryAfterMs: this.estimateMs(this.waiters.length + 1, slots, at, settings),
        });
      });
      // A person's create goes after the people already waiting and before every background create.
      this.waiters.splice(background ? this.waiters.length : this.foregroundWaiting(), 0, waiter);
      this.armLeaseTimer(slots);
    });
  }

  /** Gives `holder`'s slot back (a no-op when it has none) and admits the next waiters in arrival order. */
  async release(holder: string): Promise<void> {
    const slots = await this.load();
    const now = this.clock.now();
    const held = slots.get(holder);
    if (held !== undefined) {
      slots.delete(holder);
      this.meanHoldMs = 0.8 * this.meanHoldMs + 0.2 * Math.max(0, now - held.startedMs);
      quietly(this.storage.delete(`${PREFIX}${holder}`));
    }
    this.pump(slots, now);
  }

  private load(): Promise<Map<string, Slot>> {
    if (this.slots !== null) return Promise.resolve(this.slots);
    this.loading ??= this.storage.list({ prefix: PREFIX }).then((stored) => {
      const slots = new Map<string, Slot>();
      for (const [key, value] of stored) if (isSlot(value)) slots.set(key.slice(PREFIX.length), value);
      this.slots ??= slots;
      return this.slots;
    });
    return this.loading;
  }

  /** The people's creates waiting: they are always the front of the queue. */
  private foregroundWaiting(): number {
    const first = this.waiters.findIndex((waiter) => waiter.background);
    return first < 0 ? this.waiters.length : first;
  }

  private take(slots: Map<string, Slot>, holder: string, startedMs: number, now: number, settings: CreateAdmissionSettings, background = false) {
    const slot: Slot = background ? { startedMs, untilMs: now + settings.leaseMs, background: true } : { startedMs, untilMs: now + settings.leaseMs };
    slots.set(holder, slot);
    quietly(this.storage.put(`${PREFIX}${holder}`, slot));
  }

  private expire(slots: Map<string, Slot>, now: number) {
    for (const [holder, slot] of slots) {
      if (slot.untilMs > now) continue;
      slots.delete(holder);
      quietly(this.storage.delete(`${PREFIX}${holder}`));
    }
  }

  /**
   * Free slots go to the waiters in queue order (people first, then background creates, each in arrival order); each
   * one's own cap is the cap it asked under, and a background create also its `backgroundCap`.
   */
  private pump(slots: Map<string, Slot>, now: number) {
    this.expire(slots, now);
    for (;;) {
      const next = this.waiters[0];
      if (next === undefined || slots.size >= next.settings.cap) break;
      if (next.background && backgroundHeld(slots) >= backgroundCap(next.settings.cap)) break;
      const waiter = this.waiters.shift();
      if (waiter === undefined) break;
      waiter.cancel();
      this.take(slots, waiter.holder, now, now, waiter.settings, waiter.background);
      waiter.answer({ admitted: true, waitedMs: now - waiter.arrivedMs, inFlight: slots.size, queued: this.waiters.length });
    }
    this.armLeaseTimer(slots);
  }

  /** While anyone waits, the earliest lease end frees a slot (a Worker that died mid-create). */
  private armLeaseTimer(slots: Map<string, Slot>) {
    this.cancelLeaseTimer?.();
    this.cancelLeaseTimer = null;
    if (this.waiters.length === 0 || slots.size === 0) return;
    const until = Math.min(...[...slots.values()].map((slot) => slot.untilMs));
    this.cancelLeaseTimer = this.clock.after(until - this.clock.now(), () => {
      this.cancelLeaseTimer = null;
      this.pump(slots, this.clock.now());
    });
  }

  /**
   * When the `position`th waiter should get a slot: the slots free one by one, each create holding its slot about
   * `meanHoldMs`, so position p waits for the p-th release, which comes about ceil(p / cap) holds after the oldest
   * create started, less what the oldest has already held.
   */
  private estimateMs(position: number, slots: Map<string, Slot>, now: number, settings: CreateAdmissionSettings): number {
    const cap = Math.max(1, settings.cap);
    const free = Math.max(0, cap - slots.size);
    if (position <= free) return 0;
    const ages = [...slots.values()].map((slot) => now - slot.startedMs).sort((a, b) => b - a);
    const rounds = Math.ceil((position - free) / cap);
    const column = (position - free - 1) % cap;
    const age = ages[column] ?? 0;
    return Math.max(0, rounds * this.meanHoldMs - Math.min(age, this.meanHoldMs));
  }
}

/** The slots background creates may hold together: all but one, so a person's create always has one (a cap of 1: it). */
export const backgroundCap = (cap: number) => Math.max(1, cap - 1);

const backgroundHeld = (slots: Map<string, Slot>) => {
  let held = 0;
  for (const slot of slots.values()) if (slot.background === true) held++;
  return held;
};

/** What a provider create asks before it sends (live-create.ts); null in UpstreamConfig means no queue. */
export interface CreateAdmissionClient {
  readonly admit: (holder: string, background?: boolean) => Promise<CreateAdmission>;
  readonly release: (holder: string) => Promise<void>;
}

/** A queue in this isolate (tests, and any host with one process). */
export const localCreateAdmission = (queue: CreateAdmissionQueue, settings: CreateAdmissionSettings): CreateAdmissionClient => ({
  admit: (holder, background) => queue.admit(holder, settings, background === true),
  release: (holder) => queue.release(holder),
});

interface CreateQueueStub {
  admitCreate(holder: string, cap: number, queueWaitMs: number, leaseMs: number, background?: boolean): Promise<unknown>;
  releaseCreate(holder: string): Promise<unknown>;
}

/** Live: the environment's one queue object. The answer crosses an RPC boundary, so it is decoded. */
export const durableObjectCreateAdmission = (stubOf: () => CreateQueueStub, settings: CreateAdmissionSettings): CreateAdmissionClient => ({
  admit: async (holder, background) => Schema.decodeUnknownSync(CreateAdmission)(await stubOf().admitCreate(holder, settings.cap, settings.queueWaitMs, settings.leaseMs, background === true)),
  release: async (holder) => { await stubOf().releaseCreate(holder); },
});

/**
 * PROVIDER_CREATE_CONCURRENCY: unset is the measured default, "none" (or "0") turns the queue off, else a whole
 * number 1..1000. PROVIDER_CREATE_QUEUE_WAIT_MS: unset is the derived default, else 0..120000. A value that does not
 * parse keeps the default, so a typo never turns the queue off.
 */
export const parseCreateAdmission = (concurrency: string | undefined, queueWaitMs: string | undefined): CreateAdmissionSettings | null => {
  const raw = concurrency?.trim().toLowerCase();
  if (raw === "none" || raw === "0") return null;
  const cap = raw !== undefined && /^[0-9]{1,4}$/u.test(raw) && Number(raw) >= 1 && Number(raw) <= 1000 ? Number(raw) : DEFAULT_CREATE_CONCURRENCY;
  const wait = queueWaitMs?.trim();
  const waitMs = wait !== undefined && /^[0-9]{1,6}$/u.test(wait) && Number(wait) <= 120_000 ? Number(wait) : DEFAULT_CREATE_QUEUE_WAIT_MS;
  return { cap, queueWaitMs: waitMs, leaseMs: CREATE_SLOT_LEASE_MS };
};
