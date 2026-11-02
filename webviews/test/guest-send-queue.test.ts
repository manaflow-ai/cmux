// The guest page's single paced outbox: offline backlog, online bursts, a transient room refusal,
// stable ids through reconnect and no sends after revoke. The fake clock has zero wall-clock sleeps.
import { expect, test } from "bun:test";
import { GuestPrompts } from "../src/agent-session/guest/guestPrompts";
import { GUEST_PROMPT_GAP_MS, GUEST_PROMPT_RETRY_MS, GuestSendQueue, type GuestSendTimers } from "../src/agent-session/guest/guestSendQueue";
import { memoryStorage } from "../src/agent-session/guest/fixtures/liveChat";

function fakeClock() {
  let now = 0;
  let nextId = 0;
  const jobs = new Map<number, { at: number; run: () => void }>();
  const timers: GuestSendTimers = {
    now: () => now,
    set: (run, ms) => {
      const id = ++nextId;
      jobs.set(id, { at: now + ms, run });
      return id;
    },
    clear: (id) => void jobs.delete(id as number),
  };
  const advance = (ms: number) => {
    const until = now + ms;
    for (let steps = 0; steps < 1_000; steps += 1) {
      const next = [...jobs].filter(([, job]) => job.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) { now = until; return; }
      now = next[1].at;
      jobs.delete(next[0]);
      next[1].run();
    }
    throw new Error("a paced guest outbox scheduled too many timers");
  };
  return { timers, advance, jobs };
}

function fixture() {
  const clock = fakeClock();
  let id = 0;
  const prompts = new GuestPrompts("share", memoryStorage(), (bytes) => bytes.fill(++id), clock.timers.now);
  const sent: Array<{ id: string; text: string; at: number }> = [];
  const queue = new GuestSendQueue(prompts, (prompt) => {
    sent.push({ id: prompt.clientId, text: prompt.text, at: clock.timers.now() });
    return true;
  }, clock.timers);
  const add = (text: string) => {
    const p = prompts.add(text);
    queue.queued();
    return p;
  };
  return { clock, prompts, sent, queue, add };
}

test("five messages queued while offline drain in order, at most one every 600 ms", () => {
  const f = fixture();
  const added = Array.from({ length: 5 }, (_, index) => f.add(`offline ${index}`));
  expect(f.sent).toEqual([]);
  f.queue.snapshot([]);
  expect(f.sent.map((msg) => msg.text)).toEqual(["offline 0"]);
  for (let index = 1; index < 5; index += 1) {
    f.clock.advance(GUEST_PROMPT_GAP_MS - 1);
    expect(f.sent.length).toBe(index);
    f.clock.advance(1);
    expect(f.sent.length).toBe(index + 1);
  }
  expect(f.sent.map((msg) => msg.id)).toEqual(added.map((prompt) => prompt.clientId));
  expect(f.sent.map((msg) => msg.at)).toEqual([0, 600, 1200, 1800, 2400]);
  f.queue.stop();
});

test("rapid sends while live use the same pacing as a replayed backlog", () => {
  const f = fixture();
  f.queue.snapshot([]);
  const first = f.add("one");
  f.add("two");
  f.add("three");
  expect(f.sent.map((msg) => msg.text)).toEqual(["one"]);
  f.queue.status({ client_id: first.clientId, state: "held" });
  f.clock.advance(GUEST_PROMPT_GAP_MS);
  expect(f.sent.map((msg) => msg.text)).toEqual(["one", "two"]);
  f.clock.advance(GUEST_PROMPT_GAP_MS);
  expect(f.sent.map((msg) => msg.text)).toEqual(["one", "two", "three"]);
  f.queue.stop();
});

test("share.rate_limited is retried after a gap with the same client id, then held", () => {
  const f = fixture();
  f.queue.snapshot([]);
  const prompt = f.add("retry me");
  expect(f.sent.map((msg) => msg.id)).toEqual([prompt.clientId]);
  f.queue.status({ client_id: prompt.clientId, state: "refused", reason: "share.rate_limited" });
  expect(f.prompts.unsent().map((each) => each.clientId)).toEqual([prompt.clientId]);
  f.clock.advance(GUEST_PROMPT_RETRY_MS - 1);
  expect(f.sent.length).toBe(1);
  f.clock.advance(1);
  expect(f.sent.map((msg) => msg.id)).toEqual([prompt.clientId, prompt.clientId]);
  f.queue.status({ client_id: prompt.clientId, state: "held" });
  expect(f.prompts.held()).toEqual([prompt.clientId]);
  f.queue.disconnected();
  f.queue.snapshot([{ client_id: prompt.clientId, state: "held" }]);
  f.clock.advance(2_000);
  expect(f.sent.length).toBe(2);
  f.queue.stop();
});

test("a reconnect replays an unanswered message once with the same id", () => {
  const f = fixture();
  f.queue.snapshot([]);
  const prompt = f.add("sent before drop");
  f.queue.disconnected();
  f.clock.advance(100);
  f.queue.snapshot([]);
  expect(f.sent.length).toBe(1);
  f.clock.advance(GUEST_PROMPT_GAP_MS - 100);
  expect(f.sent.map((msg) => msg.id)).toEqual([prompt.clientId, prompt.clientId]);
  f.queue.status({ client_id: prompt.clientId, state: "approved" });
  f.queue.disconnected();
  f.queue.snapshot([]);
  f.clock.advance(2_000);
  expect(f.sent.length).toBe(2);
  f.queue.stop();
});

test("permanent refusals remain decided; end cancels unsent messages and timers", () => {
  const f = fixture();
  f.queue.snapshot([]);
  const first = f.add("accepted");
  f.add("queued until stop");
  f.queue.status({ client_id: first.clientId, state: "refused", reason: "share.too_large" });
  expect(f.prompts.unsent().length).toBe(1);
  expect(f.clock.jobs.size).toBe(1);
  f.queue.stop();
  expect(f.clock.jobs.size).toBe(0);
  f.clock.advance(5_000);
  expect(f.sent.map((msg) => msg.text)).toEqual(["accepted"]);
});

test("a timeout refusal can be superseded by a delayed held and owner decision", () => {
  const f = fixture();
  f.queue.snapshot([]);
  const prompt = f.add("eventually accepted");
  f.queue.status({ client_id: prompt.clientId, state: "refused", reason: "agent_session.timeout" });
  expect(f.prompts.list()[0]?.state).toBe("refused");
  f.queue.status({ client_id: prompt.clientId, state: "held" });
  expect(f.prompts.list()[0]?.state).toBe("held");
  f.queue.status({ client_id: prompt.clientId, state: "approved" });
  expect(f.prompts.list()[0]?.state).toBe("approved");
  expect(f.sent).toHaveLength(1);
  f.queue.stop();
});
