import { expect, test } from "bun:test";
import { memoryStorage } from "../agent-session/guest/fixtures/liveChat";
import { GuestPrompts } from "../agent-session/guest/guestPrompts";
import { ChiefUnavailable, InvalidClientMessageId, SendRefused } from "./api";
import { ChiefOutbox } from "./outbox";
import { ChiefAccessError, ExpiredSession } from "./wire";

function fakeClock() {
  let now = 0;
  let nextId = 0;
  const jobs = new Map<number, { at: number; run(): void }>();
  const clock = {
    now: () => now,
    set: (run: () => void, ms: number) => {
      const id = ++nextId;
      jobs.set(id, { at: now + ms, run });
      return id;
    },
    clear: (id: unknown) => void jobs.delete(id as number),
  };
  const advance = (ms: number) => {
    const until = now + ms;
    for (let steps = 0; steps < 100; steps++) {
      const next = [...jobs].filter(([, job]) => job.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) {
        now = until;
        return;
      }
      now = next[1].at;
      jobs.delete(next[0]);
      next[1].run();
    }
    throw new Error("Chief outbox did not stop scheduling timers");
  };
  return { clock, advance, jobs };
}

// A send reaction and its finally each run in a microtask; no elapsed time is required.
async function settle() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function fixture() {
  const time = fakeClock();
  let nextId = 0;
  const prompts = new GuestPrompts("chief:test", memoryStorage(), (bytes) => bytes.fill(++nextId), time.clock.now);
  const calls: Array<{
    text: string;
    id: string;
    signal: AbortSignal;
    settled: boolean;
    resolve(): void;
    reject(error: unknown): void;
  }> = [];
  let peak = 0;
  const terminal: string[] = [];
  const outbox = new ChiefOutbox(
    prompts,
    {
      send: (text, id, signal) =>
        new Promise<void>((resolve, reject) => {
          const call = {
            text,
            id,
            signal,
            settled: false,
            resolve: () => {
              call.settled = true;
              resolve();
            },
            reject: (error: unknown) => {
              call.settled = true;
              reject(error);
            },
          };
          calls.push(call);
          peak = Math.max(peak, calls.filter((request) => !request.settled).length);
        }),
    },
    (state) => terminal.push(state),
    time.clock,
  );
  const add = (text: string) => {
    const prompt = prompts.add(text);
    outbox.queued();
    return prompt;
  };
  const state = (id: string) => prompts.list().find((prompt) => prompt.clientId === id)?.state;
  return { time, prompts, calls, terminal, outbox, add, state, peak: () => peak };
}

test("rapid queued messages keep exactly one HTTP request active and preserve composer order", async () => {
  const f = fixture();
  f.outbox.connected();
  const added = [f.add("A"), f.add("B"), f.add("C")];
  f.outbox.queued();
  f.outbox.connected();
  expect(f.calls.map((call) => call.text)).toEqual(["A"]);
  f.calls[0]!.resolve();
  await settle();
  expect(f.calls.map((call) => call.text)).toEqual(["A", "B"]);
  f.calls[1]!.resolve();
  await settle();
  expect(f.calls.map((call) => call.text)).toEqual(["A", "B", "C"]);
  f.calls[2]!.resolve();
  await settle();
  expect(added.map((prompt) => f.state(prompt.clientId))).toEqual(["approved", "approved", "approved"]);
  expect(f.peak()).toBe(1);
  expect(f.time.jobs.size).toBe(0);
  f.outbox.stop();
});

test("A's unavailable retries back off with the original id before B or C can be submitted", async () => {
  const f = fixture();
  const a = f.add("A");
  f.add("B");
  f.add("C");
  f.outbox.connected();
  f.calls[0]!.reject(new ChiefUnavailable());
  await settle();
  f.time.advance(999);
  expect(f.calls.map((call) => call.text)).toEqual(["A"]);
  f.time.advance(1);
  expect(f.calls.map((call) => call.text)).toEqual(["A", "A"]);
  expect(f.calls[1]!.id).toBe(a.clientId);
  f.calls[1]!.reject(new ChiefUnavailable());
  await settle();
  f.time.advance(1_999);
  expect(f.calls).toHaveLength(2);
  f.time.advance(1);
  expect(f.calls.map((call) => call.text)).toEqual(["A", "A", "A"]);
  f.calls[2]!.resolve();
  await settle();
  expect(f.calls.map((call) => call.text)).toEqual(["A", "A", "A", "B"]);
  f.calls[3]!.resolve();
  await settle();
  expect(f.calls.map((call) => call.text)).toEqual(["A", "A", "A", "B", "C"]);
  expect(f.peak()).toBe(1);
  f.outbox.stop();
  f.calls[4]!.resolve();
  await settle();
});

test("disconnect and reconnect while A awaits its HTTP receipt do not duplicate A", async () => {
  const f = fixture();
  f.outbox.connected();
  const a = f.add("A");
  f.add("B");
  f.outbox.disconnected();
  f.outbox.connected();
  f.outbox.connected();
  f.time.advance(60_000);
  expect(f.calls.map((call) => call.id)).toEqual([a.clientId]);
  expect(f.calls[0]!.signal.aborted).toBe(false);
  f.calls[0]!.resolve();
  await settle();
  expect(f.calls.map((call) => call.text)).toEqual(["A", "B"]);
  expect(f.peak()).toBe(1);
  f.outbox.stop();
  f.calls[1]!.resolve();
  await settle();
});

test("an offline retry remains paused and resumes the same id once connected", async () => {
  const f = fixture();
  f.outbox.connected();
  const a = f.add("A");
  f.calls[0]!.reject(new ChiefUnavailable());
  await settle();
  expect(f.time.jobs.size).toBe(1);
  f.outbox.disconnected();
  expect(f.time.jobs.size).toBe(0);
  f.time.advance(60_000);
  f.outbox.queued();
  expect(f.calls).toHaveLength(1);
  expect(f.state(a.clientId)).toBe("sending");
  f.outbox.connected();
  expect(f.calls.map((call) => call.id)).toEqual([a.clientId, a.clientId]);
  f.outbox.stop();
  f.calls[1]!.resolve();
  await settle();
});

test("a wire acknowledgement wins against a late HTTP rejection", async () => {
  const f = fixture();
  f.outbox.connected();
  const a = f.add("A");
  f.add("B");
  f.outbox.accepted(a.clientId);
  expect(f.state(a.clientId)).toBe("approved");
  expect(f.calls).toHaveLength(1);
  f.calls[0]!.reject(new SendRefused());
  await settle();
  expect(f.state(a.clientId)).toBe("approved");
  expect(f.calls.map((call) => call.text)).toEqual(["A", "B"]);
  expect(f.time.jobs.size).toBe(0);
  expect(f.peak()).toBe(1);
  f.outbox.stop();
  f.calls[1]!.resolve();
  await settle();
});

for (const outcome of ["resolve", "reject"] as const) {
  test(`stop aborts HTTP and ignores its late ${outcome} and wire acknowledgement`, async () => {
    const f = fixture();
    f.outbox.connected();
    const a = f.add("A");
    f.add("B");
    const before = f.prompts.list();
    f.outbox.stop();
    expect(f.calls[0]!.signal.aborted).toBe(true);
    if (outcome === "resolve") f.calls[0]!.resolve();
    else f.calls[0]!.reject(new ChiefUnavailable());
    await settle();
    f.outbox.accepted(a.clientId);
    f.outbox.connected();
    f.outbox.queued();
    f.time.advance(60_000);
    expect(f.prompts.list()).toBe(before);
    expect(f.calls).toHaveLength(1);
    expect(f.time.jobs.size).toBe(0);
    expect(f.terminal).toEqual([]);
  });
}

test("a refused message is retried manually with exactly its original id and text", async () => {
  const f = fixture();
  f.outbox.connected();
  const a = f.add("A");
  f.calls[0]!.reject(new SendRefused());
  await settle();
  expect(f.state(a.clientId)).toBe("refused");
  f.time.advance(60_000);
  expect(f.calls).toHaveLength(1);
  f.prompts.retry(a.clientId);
  f.outbox.queued();
  expect(f.calls.map(({ id, text }) => ({ id, text }))).toEqual([
    { id: a.clientId, text: "A" },
    { id: a.clientId, text: "A" },
  ]);
  f.calls[1]!.resolve();
  await settle();
  expect(f.state(a.clientId)).toBe("approved");
  f.outbox.stop();
});

test("invalid restored client ids fail visibly rather than entering a network retry loop", async () => {
  const f = fixture();
  f.outbox.connected();
  const a = f.add("A");
  f.calls[0]!.reject(new InvalidClientMessageId());
  await settle();
  expect(f.state(a.clientId)).toBe("refused");
  f.time.advance(60_000);
  expect(f.calls).toHaveLength(1);
  expect(f.time.jobs.size).toBe(0);
  f.outbox.stop();
});

for (const [failure, terminal] of [
  [new ExpiredSession(), "expired"],
  [new ChiefAccessError(), "inaccessible"],
] as const) {
  test(`${terminal} stops queued sends without changing their retry ids`, async () => {
    const f = fixture();
    f.outbox.connected();
    const a = f.add("A");
    f.add("B");
    f.calls[0]!.reject(failure);
    await settle();
    expect(f.terminal).toEqual([terminal]);
    expect(f.calls[0]!.signal.aborted).toBe(true);
    expect(f.state(a.clientId)).toBe("sending");
    f.outbox.connected();
    f.time.advance(60_000);
    expect(f.calls).toHaveLength(1);
    expect(f.time.jobs.size).toBe(0);
  });
}
