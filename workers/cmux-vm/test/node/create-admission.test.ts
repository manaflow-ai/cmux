/**
 * The provider create queue (src/limits/create-admission.ts) under a burst.
 *
 * The provider model is staging's, 2026-11-27: a create that arrives with at most M = 3 others in flight is answered
 * after `HOLD_MS`; one that arrives past that hangs until our 120 s create timeout, with nothing made. The client model
 * is cmux-platform's: a 503 or a timeout is retried with the same key after min(30 s, 1 s * 2^attempt), for as long as
 * its 5 minute retry window allows. Every create in a burst calls `admit` before any slot is released (the handbook's
 * `burst-admitted-one-per-round.md` ask), and the test reads the time until the last one is admitted.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CREATE_SLOT_LEASE_MS,
  CreateAdmissionQueue,
  DEFAULT_CREATE_CONCURRENCY,
  DEFAULT_CREATE_QUEUE_WAIT_MS,
  INITIAL_HOLD_MS,
  PROVIDER_CREATE_BUDGET_MS,
  parseCreateAdmission,
  type CreateAdmission,
  type CreateAdmissionSettings,
} from "../../src/limits/create-admission.ts";
import { memoryLedgerStorage } from "../../src/limits/ledger.ts";
import { upstreamConfigOf } from "../../src/upstream/live.ts";
import { Redacted } from "effect";

const PROVIDER_TIMEOUT_MS = 120_000;
const HOLD_MS = 14_000;
const HANGS_PAST = 3;
const RETRY_WINDOW_MS = 5 * 60_000;
const SETTINGS: CreateAdmissionSettings = { cap: DEFAULT_CREATE_CONCURRENCY, queueWaitMs: DEFAULT_CREATE_QUEUE_WAIT_MS, leaseMs: CREATE_SLOT_LEASE_MS };

beforeEach(() => { vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] }); vi.setSystemTime(0); });
afterEach(() => { vi.useRealTimers(); });

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** The staging provider: answers in HOLD_MS with at most HANGS_PAST in flight at arrival, else hangs to the timeout. */
const makeProvider = () => {
  let inFlight = 0, peak = 0, hung = 0;
  return {
    get peak() { return peak; },
    get hung() { return hung; },
    create: async (): Promise<boolean> => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      const hangs = inFlight > HANGS_PAST;
      if (hangs) hung++;
      await sleep(hangs ? PROVIDER_TIMEOUT_MS : HOLD_MS);
      inFlight--;
      return !hangs;
    },
  };
};

interface Burst {
  readonly made: number;
  readonly hung: number;
  readonly peakInFlight: number;
  /** When the last create was admitted to send (its final, successful attempt). */
  readonly lastAdmittedMs: number;
  /** When the last create's VM was made. */
  readonly lastMadeMs: number;
  /** The longest any one attempt took to answer the client, sent or refused. */
  readonly longestAttemptMs: number;
  /** The longest a refusal took to come back. */
  readonly longestRefusalMs: number;
  readonly refusals: number;
}

/** N creates at t = 0 through the platform's retry loop, queued (`settings`) or not (null). */
const burst = async (n: number, settings: CreateAdmissionSettings | null): Promise<Burst> => {
  vi.setSystemTime(0);
  const queue = new CreateAdmissionQueue(memoryLedgerStorage());
  const provider = makeProvider();
  let lastAdmittedMs = 0, lastMadeMs = 0, longestAttemptMs = 0, longestRefusalMs = 0, refusals = 0, made = 0;
  const one = async (holder: string) => {
    for (let attempt = 0; Date.now() < RETRY_WINDOW_MS; attempt++) {
      const started = Date.now();
      const admission: CreateAdmission | null = settings === null ? null : await queue.admit(holder, settings);
      if (admission !== null && !admission.admitted) {
        refusals++;
        longestRefusalMs = Math.max(longestRefusalMs, Date.now() - started);
        longestAttemptMs = Math.max(longestAttemptMs, Date.now() - started);
      } else {
        const admittedAt = Date.now();
        const ok = await provider.create();
        if (settings !== null) await queue.release(holder);
        longestAttemptMs = Math.max(longestAttemptMs, Date.now() - started);
        if (ok) {
          made++;
          lastAdmittedMs = Math.max(lastAdmittedMs, admittedAt);
          lastMadeMs = Math.max(lastMadeMs, Date.now());
          return;
        }
      }
      await sleep(Math.min(30_000, 1000 * 2 ** attempt));
    }
  };
  const all = Promise.all(Array.from({ length: n }, (_, index) => one(`vm_${index}`)));
  await vi.advanceTimersByTimeAsync(RETRY_WINDOW_MS + PROVIDER_TIMEOUT_MS + 60_000);
  await all;
  return { made, hung: provider.hung, peakInFlight: provider.peak, lastAdmittedMs, lastMadeMs, longestAttemptMs, longestRefusalMs, refusals };
};

describe("a burst of creates against a provider that hangs past 3 in flight", () => {
  for (const n of [30, 50]) {
    it(`queued: all ${n} are made, none hangs, every refusal is quick`, async () => {
      const queued = await burst(n, SETTINGS);
      const unqueued = await burst(n, null);
      // The numbers the PR quotes: one model, both arms.
      process.stdout.write(`create-admission burst ${JSON.stringify({ n, queued, unqueued })}\n`);
      expect(queued.made).toBe(n);
      expect(queued.hung).toBe(0);
      expect(queued.peakInFlight).toBeLessThanOrEqual(HANGS_PAST);
      // A refusal is at once or at the end of the bounded wait, never a provider timeout.
      expect(queued.longestRefusalMs).toBeLessThanOrEqual(DEFAULT_CREATE_QUEUE_WAIT_MS);
      expect(queued.longestAttemptMs).toBeLessThan(PROVIDER_TIMEOUT_MS);
      // Without the queue the same burst sends past the provider's limit, and those creates hang to the timeout.
      expect(unqueued.hung).toBeGreaterThan(0);
      expect(unqueued.longestAttemptMs).toBe(PROVIDER_TIMEOUT_MS);
      expect(queued.lastMadeMs).toBeLessThan(unqueued.lastMadeMs);
    });
  }
});

describe("CreateAdmissionQueue", () => {
  const settle = () => vi.advanceTimersByTimeAsync(0);

  it("decides every create of a burst on its first call: cap admitted, the wait that fits queued, the rest refused at once", async () => {
    const queue = new CreateAdmissionQueue(memoryLedgerStorage());
    const answers: Array<CreateAdmission | null> = Array.from({ length: 30 }, () => null);
    const calls = answers.map((_, index) => queue.admit(`vm_${index}`, SETTINGS).then((answer) => { answers[index] = answer; }));
    await settle();
    expect(answers.slice(0, 3).every((answer) => answer?.admitted === true && answer.waitedMs === 0)).toBe(true);
    // With 3 slots held a hold of 14 s each, the next 3 expect a slot within 14 s (under 25 s): they queue.
    expect(answers.slice(3, 6)).toEqual([null, null, null]);
    // The 7th would wait two holds (28 s), past the 25 s budget: refused now, nothing waited.
    expect(answers.slice(6).every((answer) => answer?.admitted === false && answer.reason === "queue_full" && answer.waitedMs === 0)).toBe(true);
    expect(queue.state).toMatchObject({ inFlight: 3, queued: 3 });
    // Releases hand slots over in arrival order.
    await vi.advanceTimersByTimeAsync(5_000);
    await queue.release("vm_1");
    await settle();
    expect(answers[3]).toMatchObject({ admitted: true, waitedMs: 5_000 });
    expect(answers[4]).toBeNull();
    await queue.release("vm_0");
    await queue.release("vm_2");
    await settle();
    expect(answers[4]).toMatchObject({ admitted: true });
    expect(answers[5]).toMatchObject({ admitted: true });
    await Promise.all(calls);
  });

  it("answers a queued create whose slot does not come within the budget with wait_expired, at the budget", async () => {
    const queue = new CreateAdmissionQueue(memoryLedgerStorage());
    for (const holder of ["a", "b", "c"]) expect(await queue.admit(holder, SETTINGS)).toMatchObject({ admitted: true });
    const waiting = queue.admit("d", SETTINGS);
    await vi.advanceTimersByTimeAsync(DEFAULT_CREATE_QUEUE_WAIT_MS);
    expect(await waiting).toMatchObject({ admitted: false, reason: "wait_expired", waitedMs: DEFAULT_CREATE_QUEUE_WAIT_MS });
    expect(queue.state.queued).toBe(0);
    // Its slot was never taken: a release later admits nobody stale.
    await queue.release("a");
    expect(queue.state.inFlight).toBe(2);
  });

  it("frees the slot of a create whose Worker never released it once its lease ends, and admits the next waiter", async () => {
    const queue = new CreateAdmissionQueue(memoryLedgerStorage());
    const lease: CreateAdmissionSettings = { ...SETTINGS, cap: 1, queueWaitMs: 20_000, leaseMs: 10_000 };
    expect(await queue.admit("dead", lease)).toMatchObject({ admitted: true });
    const waiting = queue.admit("next", lease);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(await waiting).toMatchObject({ admitted: true, waitedMs: 10_000 });
  });

  it("keeps a slot whose create is still polled as a background request (cmux#61044, up to the 240 s budget): no fourth create in", async () => {
    expect(CREATE_SLOT_LEASE_MS).toBeGreaterThan(PROVIDER_CREATE_BUDGET_MS);
    const queue = new CreateAdmissionQueue(memoryLedgerStorage());
    for (const holder of ["a", "b", "c"]) expect(await queue.admit(holder, SETTINGS)).toMatchObject({ admitted: true });
    // Every slot is still inside its provider call for the whole of the next create's wait; the old 130 s lease had
    // freed all three long before.
    await vi.advanceTimersByTimeAsync(PROVIDER_CREATE_BUDGET_MS - DEFAULT_CREATE_QUEUE_WAIT_MS - 1_000);
    const waiting = queue.admit("d", SETTINGS);
    await settle();
    expect(queue.state.inFlight).toBe(3);
    await vi.advanceTimersByTimeAsync(DEFAULT_CREATE_QUEUE_WAIT_MS);
    expect(await waiting).toMatchObject({ admitted: false });
  });

  it("keeps the slots it handed out across a restart of its object", async () => {
    const storage = memoryLedgerStorage();
    const first = new CreateAdmissionQueue(storage);
    for (const holder of ["a", "b", "c"]) await first.admit(holder, SETTINGS);
    await settle();
    const restarted = new CreateAdmissionQueue(storage);
    expect(await restarted.admit("d", { ...SETTINGS, queueWaitMs: 0 })).toMatchObject({ admitted: false, reason: "queue_full", inFlight: 3 });
    await restarted.release("a");
    expect(await restarted.admit("d", SETTINGS)).toMatchObject({ admitted: true, inFlight: 3 });
  });

  it("lets a create that already holds a slot (a retry after a lost answer) keep it instead of queueing behind itself", async () => {
    const queue = new CreateAdmissionQueue(memoryLedgerStorage());
    const one: CreateAdmissionSettings = { ...SETTINGS, cap: 1 };
    expect(await queue.admit("a", one)).toMatchObject({ admitted: true });
    expect(await queue.admit("a", one)).toMatchObject({ admitted: true, inFlight: 1, queued: 0 });
  });

  it("learns the hold from releases: fast creates let more wait inside the budget", async () => {
    const queue = new CreateAdmissionQueue(memoryLedgerStorage());
    for (let round = 0; round < 20; round++) {
      await queue.admit("x", SETTINGS);
      await vi.advanceTimersByTimeAsync(2_000);
      await queue.release("x");
    }
    expect(queue.state.meanHoldMs).toBeLessThan(INITIAL_HOLD_MS / 4);
    for (const holder of ["a", "b", "c"]) await queue.admit(holder, SETTINGS);
    const answers: Array<CreateAdmission | null> = Array.from({ length: 12 }, () => null);
    answers.forEach((_, index) => { void queue.admit(`w${index}`, SETTINGS).then((answer) => { answers[index] = answer; }); });
    await settle();
    expect(queue.state.queued).toBeGreaterThan(3);
  });
});

describe("parseCreateAdmission", () => {
  it("defaults to the measured cap and the derived wait, turns off only on none or 0, and ignores a value that does not parse", () => {
    expect(parseCreateAdmission(undefined, undefined)).toEqual(SETTINGS);
    expect(parseCreateAdmission("none", undefined)).toBeNull();
    expect(parseCreateAdmission("0", "1000")).toBeNull();
    expect(parseCreateAdmission("8", "5000")).toEqual({ ...SETTINGS, cap: 8, queueWaitMs: 5000 });
    expect(parseCreateAdmission("three", "-1")).toEqual(SETTINGS);
    expect(parseCreateAdmission("100000", "999999")).toEqual(SETTINGS);
  });
});

describe("the Worker's upstream config", () => {
  it("hands the provider create queue to the client, with every other field (staging 2026-11-27: the layer dropped it)", () => {
    const createAdmission = { admit: async () => ({ admitted: true as const, waitedMs: 0, inFlight: 1, queued: 0 }), release: async () => {} };
    const fetch = async () => new Response(null);
    const config = upstreamConfigOf({ baseUrl: "https://provider.test/", apiKey: "k", environment: "staging", createAdmission, fetch, timeoutMs: 5, backgroundPollMs: 2, startPollMs: 3 });
    expect(config.createAdmission).toBe(createAdmission);
    expect(config.fetch).toBe(fetch);
    expect({ ...config, apiKey: Redacted.value(config.apiKey) }).toEqual({ baseUrl: "https://provider.test/", apiKey: "k", environment: "staging", createAdmission, fetch, timeoutMs: 5, backgroundPollMs: 2, startPollMs: 3 });
  });
});
