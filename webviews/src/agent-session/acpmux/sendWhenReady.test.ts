// A send made while acpmux starts, restarts or reconnects is held and sent once it answers, never
// failed at once (ask-5174ba0b6d, Leo 2026-11-06: "your sends are getting busted intermittently as
// things load"). Only a wait past the host's deadline fails it, with plain words and no restart advice.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { HOST_ERROR_DEADLINE_MS } from "./hostRetry";
import { failedSendText, retryHelps, sendCause } from "./sendFailure";
import { SEND_RETRY_FIRST_MS, sendWaitsForHost, sendsHeldForHost, untilHostAnswers } from "./sendWhenReady";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const notConnected = () =>
  Object.assign(new Error("The agent connection is not open."), { code: "native.not_connected" });

/// A clock the waits move: `sleep(ms)` advances it at once.
function fakeClock() {
  let at = 0;
  const waits: number[] = [];
  return {
    waits,
    now: () => at,
    sleep: async (ms: number) => {
      waits.push(ms);
      at += ms;
    },
  };
}

test("only a failure the host clears by itself holds a send", () => {
  expect(sendWaitsForHost({ code: "native.not_connected" })).toBe(true);
  expect(sendWaitsForHost({ code: "native.timed_out" })).toBe(true);
  expect(sendWaitsForHost({ code: "host_unavailable", details: { reconnecting: true } })).toBe(true);
  expect(sendWaitsForHost({ code: "known", data: { retryable: true } })).toBe(true);
  // A send's own refusals are plain errors with no code: never sent again.
  expect(sendWaitsForHost(new Error("agent_session.changed_during_send"))).toBe(false);
  expect(sendWaitsForHost({ code: "agent_session.untrusted" })).toBe(false);
  expect(sendWaitsForHost({ code: "transport.gesture_required" })).toBe(false);
  expect(sendWaitsForHost({ code: "native.not_connected", reason: "message.too_large" })).toBe(false);
  // acpmux took it, or it already shows as a failed row: never from here.
  expect(sendWaitsForHost({ code: "native.timed_out", taken: true })).toBe(false);
  expect(sendWaitsForHost({ code: "native.not_connected", failedRow: "local-1" })).toBe(false);
  expect(sendWaitsForHost(null)).toBe(false);
});

test("a send that fails while the host comes back goes once it answers", async () => {
  const clock = fakeClock();
  let tries = 0;
  let waiting = 0;
  const result = await untilHostAnswers(
    async () => {
      tries += 1;
      if (tries < 4) throw notConnected();
      return "sent";
    },
    { ...clock, waiting: () => (waiting += 1) },
  );
  expect(result).toBe("sent");
  expect(tries).toBe(4);
  expect(waiting).toBe(3);
  expect(clock.waits).toEqual([SEND_RETRY_FIRST_MS, SEND_RETRY_FIRST_MS * 2, SEND_RETRY_FIRST_MS * 4]);
});

test("the wait has an end: past the deadline the last failure is thrown", async () => {
  const clock = fakeClock();
  let tries = 0;
  const error = await untilHostAnswers(async () => {
    tries += 1;
    throw notConnected();
  }, clock).catch((caught: unknown) => caught);
  expect((error as { code?: string }).code).toBe("native.not_connected");
  expect(clock.now()).toBeLessThanOrEqual(HOST_ERROR_DEADLINE_MS);
  // Backoff doubles to 2 s: a bounded count of tries in 25 s.
  expect(tries).toBeGreaterThan(5);
  expect(tries).toBeLessThan(20);
  expect(Math.max(...clock.waits)).toBe(2_000);
});

test("a failure the host does not clear, or a send no longer wanted, stops at once", async () => {
  const clock = fakeClock();
  let tries = 0;
  await expect(
    untilHostAnswers(async () => {
      tries += 1;
      throw Object.assign(new Error("refused"), { code: "agent_session.refused" });
    }, clock),
  ).rejects.toThrow("refused");
  expect(tries).toBe(1);

  tries = 0;
  let wanted = true;
  await expect(
    untilHostAnswers(
      async () => {
        tries += 1;
        wanted = false;
        throw notConnected();
      },
      { ...clock, stop: () => !wanted },
    ),
  ).rejects.toThrow("not open");
  expect(tries).toBe(1);
});

test("a send that gave up says so calmly, keeps Retry, and never says restart", () => {
  for (const code of ["native.not_connected", "native.timed_out"]) {
    const cause = sendCause({ code });
    expect(cause).toBe("host-away");
    expect(retryHelps(cause)).toBe(true);
    const text = failedSendText({ code, message: "The agent connection is not open." }, false);
    expect(text).not.toMatch(/restart/i);
    expect(text).not.toContain("connection is not open");
  }
});

test("the composer's held count rises and falls with each held send", () => {
  const seen: boolean[] = [];
  const unsubscribe = sendsHeldForHost.subscribe(() => seen.push(sendsHeldForHost.get()));
  const first = sendsHeldForHost.hold();
  const second = sendsHeldForHost.hold();
  expect(sendsHeldForHost.get()).toBe(true);
  first();
  first();
  expect(sendsHeldForHost.get()).toBe(true);
  second();
  expect(sendsHeldForHost.get()).toBe(false);
  expect(seen).toEqual([true, false]);
  unsubscribe();
});
