// The pane's handshake loop is bounded in rate, never in time (Leo, 2026-11-24: "I feel like there are
// often these like dead hang loops"; cmux#60478, a brief forwarded as his, unverified, on "The agent service stopped. Retry": "retry on its
// own and never send messages like this. just remove it"). Before cmux#54312 a pane whose agent service
// never came back asked again every 2 s forever (cmux#49148: 490 reconnects an hour from one pane); then
// the loop stopped at SELF_RETRY_SAID_MS and waited on a click. Now, past SELF_RETRY_SAID_MS, it keeps
// asking at most every REFUSED_RETRY_MAX_MS (`slow`), and an event (the window shown or focused, the
// network back, the host's word that acpmux answers again) asks at once.
//
// These tests run the loop's rules on a simulated clock: the asks an hour without a daemon, before
// and after, and the time from the daemon's return to the pane's next ask.
import { expect, test } from "bun:test";
import {
  CONNECTION_STABLE_MS,
  hostRetryStep,
  hostWakeAsks,
  lostRetryDelay,
  lostRetryStep,
  nextRetryDelay,
  REFUSED_RETRY_MAX_MS,
  RETRY_FIRST_MS,
  SELF_RETRY_SAID_MS,
} from "../src/agent-session/acpmux/hostRetry";

const HOUR_MS = 3_600_000;
/// A handshake that finds no daemon (the lookup fails at once on a missing socket).
const daemonGone = Object.assign(new Error("acpmux is not running"), { code: "native.not_connected" });
const machineUnreachable = new Error("peer_unreachable: studio (connecting, last seen 3s ago)");

/// The asks an hour of failed handshakes takes, as the pane's catch block schedules them.
function asksInAnHour(bounded: boolean, error: unknown = daemonGone): number {
  let now = 0;
  let delay = RETRY_FIRST_MS;
  let asks = 0;
  while (now < HOUR_MS) {
    asks += 1;
    let wait = delay;
    if (bounded) {
      const step = hostRetryStep({ error, troubleForMs: now, waitMs: delay });
      if (step.kind === "stop") break;
      wait = step.waitMs;
    }
    now += wait;
    delay = nextRetryDelay(delay, true);
  }
  return asks;
}

test("a pane whose agent service never comes back keeps asking, slowly, for the whole hour", () => {
  const before = asksInAnHour(false);
  const after = asksInAnHour(true);
  console.log(`asks an hour without a daemon: unbounded ${before}, slowed ${after}`);
  // Unbounded: one ask every 2 s for the whole hour.
  expect(before).toBeGreaterThan(1_700);
  // Slowed: the asks of the first two minutes, then one every 30 s until the hour ends, never none.
  const quick = Math.ceil(SELF_RETRY_SAID_MS / 2_000) + 8;
  const slow = Math.floor((HOUR_MS - SELF_RETRY_SAID_MS) / REFUSED_RETRY_MAX_MS);
  expect(after).toBeGreaterThanOrEqual(slow);
  expect(after).toBeLessThanOrEqual(quick + slow + 1);
});

test("past the bound the loop slows and never stops, except a chat too large", () => {
  expect(hostRetryStep({ error: daemonGone, troubleForMs: SELF_RETRY_SAID_MS - 1, waitMs: 2_000 })).toEqual({
    kind: "retry",
    waitMs: 2_000,
  });
  expect(hostRetryStep({ error: daemonGone, troubleForMs: SELF_RETRY_SAID_MS, waitMs: 2_000 })).toEqual({
    kind: "retry",
    waitMs: REFUSED_RETRY_MAX_MS,
    slow: true,
  });
  // acpmux reconnects a machine's link itself and tells the pane nothing: no event to wait for, so
  // it keeps a slow timer.
  expect(hostRetryStep({ error: machineUnreachable, troubleForMs: HOUR_MS, waitMs: 2_000 })).toEqual({
    kind: "retry",
    waitMs: REFUSED_RETRY_MAX_MS,
    slow: true,
  });
  // A chat too large to open gets the same reply at every ask: it stops at once (only Retry asks).
  expect(hostRetryStep({ error: { reason: "message.too_large" }, troubleForMs: 0, waitMs: 250 })).toEqual({
    kind: "stop",
  });
});

test("a daemon that drops the pane right after every connect is asked again slowly past the bound", () => {
  // Five minutes of a daemon that drops the pane 100 ms after every connect.
  const run = (bounded: boolean) => {
    let now = 0;
    let delay = RETRY_FIRST_MS;
    let connects = 0;
    while (now < 300_000) {
      connects += 1;
      now += 100;
      const lost = lostRetryDelay(delay, 100);
      const step = bounded ? lostRetryStep({ troubleForMs: now, upForMs: 100, waitMs: lost.wait }) : undefined;
      if (step?.kind === "stop") throw new Error("a flapping daemon is never given up on");
      now += step?.kind === "retry" ? step.waitMs : lost.wait;
      delay = lost.next;
    }
    return connects;
  };
  const before = run(false);
  const after = run(true);
  console.log(`connects in 5 min of a flapping daemon: unslowed ${before}, slowed ${after}`);
  expect(after).toBeLessThan(before);
  // The first two minutes at up to 10 s apart, then one every 30 s: still asking at the end.
  expect(after).toBeGreaterThanOrEqual(Math.floor(180_000 / REFUSED_RETRY_MAX_MS));
  expect(after).toBeLessThanOrEqual(30);
  // A connection that stayed up always reconnects, however long the trouble before it.
  expect(lostRetryStep({ troubleForMs: HOUR_MS, upForMs: CONNECTION_STABLE_MS, waitMs: 250 }).kind).toBe("retry");
});

test("a slow pane asks at once on the daemon's return or a person's event", () => {
  const stopped = { stopped: true, connecting: false, hidden: false, answerSpent: false };
  // The host's word that acpmux answers again: the pane asks at once (0 ms after the event).
  expect(hostWakeAsks({ ...stopped, event: "acpmux-daemon-answered" })).toBe(true);
  // Once per stop: two stopped panes never wake each other forever through their own lookups.
  expect(hostWakeAsks({ ...stopped, event: "acpmux-daemon-answered", answerSpent: true })).toBe(false);
  // A person's event asks again even then.
  expect(hostWakeAsks({ ...stopped, event: "focus", answerSpent: true })).toBe(true);
  expect(hostWakeAsks({ ...stopped, event: "visibilitychange" })).toBe(true);
  expect(hostWakeAsks({ ...stopped, event: "online" })).toBe(true);
  // Never while hidden, asking already, or not stopped.
  expect(hostWakeAsks({ ...stopped, event: "focus", hidden: true })).toBe(false);
  expect(hostWakeAsks({ ...stopped, event: "focus", connecting: true })).toBe(false);
  expect(hostWakeAsks({ ...stopped, event: "focus", stopped: false })).toBe(false);
});
