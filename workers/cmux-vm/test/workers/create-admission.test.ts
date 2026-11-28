/**
 * The provider create queue end to end: the Worker's create path, the queue in a real TENANT_LIMITS Durable Object
 * (over RPC, as deployed), and a stub provider that answers only 3 creates in flight and hangs the rest.
 */
import { env } from "cloudflare:workers";
import { afterEach, expect, it, vi } from "vitest";
import { backgroundCap, durableObjectCreateAdmission, type CreateAdmissionSettings } from "../../src/limits/create-admission.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
afterEach(async () => { await current?.dispose(); current = undefined; });

const N = 30;
const M = 3;
/** One tenant holds at most its share of the M slots (#64283), so a single team's burst sends this many. */
const SHARE = backgroundCap(M);
const QUEUE_WAIT_MS = 1_000;

/** One queue object per test: a fresh name, so tests never share slots. */
const admission = (settings: CreateAdmissionSettings) => {
  const name = `provider creates ${crypto.randomUUID()}`;
  return durableObjectCreateAdmission(() => env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(name)), settings);
};

/** A provider that answers once `open` is called, and hangs (never answers) any create past M in flight. */
const gatedProvider = (t: Harness) => {
  let inFlight = 0, peak = 0, hung = 0;
  let open: () => void = () => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  t.upstream.hooks.beforeCreate = async () => {
    inFlight++;
    peak = Math.max(peak, inFlight);
    if (inFlight > M) { hung++; return new Promise<Response>(() => {}); }
    await opened;
    inFlight--;
    return null;
  };
  return { open: () => open(), get peak() { return peak; }, get hung() { return hung; } };
};

const lines = (event: string) => {
  const seen: Array<Record<string, unknown>> = [];
  const spy = vi.spyOn(console, "error").mockImplementation((line: unknown) => {
    if (typeof line !== "string" || !line.startsWith("{")) return;
    const parsed: unknown = JSON.parse(line);
    if (typeof parsed === "object" && parsed !== null && Reflect.get(parsed, "event") === event) seen.push(Object.fromEntries(Object.entries(parsed)));
  });
  return { seen, restore: () => spy.mockRestore() };
};

it(`answers a burst of ${N} creates from one team with at most its share of ${M} sent, and a quick named retryable 503 for the rest; the same keys then create`, async () => {
  const t = (current = await makeHarness({ createAdmission: admission({ cap: M, queueWaitMs: QUEUE_WAIT_MS, leaseMs: 130_000 }) }));
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const provider = gatedProvider(t);
  const create = (index: number) => t.request("/v1/vms", { ...bearer(key), "idempotency-key": `burst-${index}` }, { method: "POST", body: { labels: { role: "burst" } } });
  const log = lines("vm_create");
  try {
    const started = Date.now();
    const answers = Array.from({ length: N }, (_, index) => create(index).then(async (response) => ({ index, status: response.status, body: await response.text(), ms: Date.now() - started })));
    // Everything but the sent creates answers while those are still held by the provider.
    const refused: Array<{ index: number; status: number; body: string; ms: number }> = [];
    for (const answer of answers) void answer.then((done) => { refused.push(done); });
    await vi.waitFor(() => { expect(refused.length).toBe(N - SHARE); }, { timeout: QUEUE_WAIT_MS * 10, interval: 20 });
    expect(provider.peak).toBe(SHARE);
    expect(provider.hung).toBe(0);
    for (const answer of refused) {
      expect(answer.status).toBe(503);
      expect(JSON.parse(answer.body)).toMatchObject({ message: "The cmux VM service is temporarily unavailable (vm-provider.createQueueFull)" });
      // At once, or at the end of the bounded wait: never the provider's 120 s.
      expect(answer.ms).toBeLessThan(QUEUE_WAIT_MS + 5_000);
    }
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(SHARE);
    provider.open();
    const sent = (await Promise.all(answers)).filter((answer) => answer.status !== 503);
    expect(sent.map((answer) => answer.status)).toEqual(Array.from({ length: SHARE }, () => 201));
    // Over its share a team's create is refused at once (queue_full) or after the bounded wait (wait_expired).
    const refusedLines = log.seen.filter((line) => line["admission"] !== undefined);
    expect(refusedLines.length).toBe(N - SHARE);
    expect(refusedLines.every((line) => typeof line["admitWaitMs"] === "number" && line["createMs"] === null && (line["admission"] === "queue_full" || line["admission"] === "wait_expired"))).toBe(true);
    // The refused keys retry, a few at a time as their slots free, and each makes one VM.
    for (let index = 0; index < N; index += SHARE) {
      const batch = await Promise.all(Array.from({ length: Math.min(SHARE, N - index) }, (_, offset) => create(index + offset)));
      expect(batch.map((response) => response.status).every((status) => status === 201 || status === 200)).toBe(true);
    }
    expect(t.upstream.vms.size).toBe(N);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(N);
    expect(provider.hung).toBe(0);
  } finally {
    log.restore();
  }
});

it("queues a create behind a full queue and sends it when a slot frees within the wait", async () => {
  const t = (current = await makeHarness({ createAdmission: admission({ cap: 1, queueWaitMs: 20_000, leaseMs: 130_000 }) }));
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const provider = gatedProvider(t);
  const create = (name: string) => t.request("/v1/vms", { ...bearer(key), "idempotency-key": name }, { method: "POST", body: { labels: { role: "burst" } } });
  const first = create("first");
  await vi.waitFor(() => { expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1); }, { timeout: 5_000, interval: 20 });
  const second = create("second");
  await new Promise((resolve) => setTimeout(resolve, 200));
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  provider.open();
  expect((await first).status).toBe(201);
  expect((await second).status).toBe(201);
  expect(provider.peak).toBe(1);
});

it("refuses a create with a retryable 503 when the queue cannot be reached, and sends nothing", async () => {
  const unreachable = { admit: () => Promise.reject(new Error("queue object unavailable")), release: () => Promise.resolve() };
  const t = (current = await makeHarness({ createAdmission: unreachable }));
  const key = await t.addKey("team_alpha", ["vm:write"]);
  const log = lines("vm_create_admission_unavailable");
  try {
    const made = await t.request("/v1/vms", bearer(key), { method: "POST", body: { labels: { role: "burst" } } });
    // #64283: an unreachable gate answers a retryable refusal rather than bypassing it.
    expect(made.status).toBe(503);
    expect(await made.json()).toMatchObject({ message: "The cmux VM service is temporarily unavailable (vm-provider.createQueueFull)" });
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(0);
    expect(log.seen).toHaveLength(1);
  } finally {
    log.restore();
  }
});
