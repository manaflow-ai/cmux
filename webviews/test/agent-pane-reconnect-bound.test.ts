// The pane's handshake loop is bounded (Leo, 2026-11-24: "I feel like there are often these like dead
// hang loops"; 2026-11-23: "infinite Reconnecting..."). Before, a pane whose agent service never came
// back asked again every 2 s forever (cmux#49148: 490 reconnects an hour from one pane), and cmux#51294
// only changed the line's words after two minutes. Now the loop stops at SELF_RETRY_SAID_MS: no timer
// asks again, the line offers Restart agent service, and an event (the window shown or focused, the
// network back, the host's word that acpmux answers again) asks once more.
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

test("a pane whose agent service never comes back stops asking at the bound", () => {
  const before = asksInAnHour(false);
  const after = asksInAnHour(true);
  console.log(`asks an hour without a daemon: before ${before}, after ${after}`);
  // Before: one ask every 2 s for the whole hour.
  expect(before).toBeGreaterThan(1_700);
  // After: the asks of the first two minutes, then none.
  expect(after).toBeLessThanOrEqual(Math.ceil(SELF_RETRY_SAID_MS / 2_000) + 8);
});

test("the bound stops the loop, except a machine link acpmux itself reconnects and a chat too large", () => {
  expect(hostRetryStep({ error: daemonGone, troubleForMs: SELF_RETRY_SAID_MS - 1, waitMs: 2_000 })).toEqual({
    kind: "retry",
    waitMs: 2_000,
  });
  expect(hostRetryStep({ error: daemonGone, troubleForMs: SELF_RETRY_SAID_MS, waitMs: 2_000 })).toEqual({
    kind: "stop",
  });
  // acpmux reconnects a machine's link itself and tells the pane nothing: no event to wait for, so
  // it keeps a slow timer.
  expect(hostRetryStep({ error: machineUnreachable, troubleForMs: HOUR_MS, waitMs: 2_000 })).toEqual({
    kind: "retry",
    waitMs: REFUSED_RETRY_MAX_MS,
  });
  // A chat too large to open gets the same reply at every ask: it stops at once (only Retry asks).
  expect(hostRetryStep({ error: { reason: "message.too_large" }, troubleForMs: 0, waitMs: 250 })).toEqual({
    kind: "stop",
  });
});

test("a daemon that drops the pane right after every connect is not asked again past the bound", () => {
  // Five minutes of a daemon that drops the pane 100 ms after every connect.
  const run = (bounded: boolean) => {
    let now = 0;
    let delay = RETRY_FIRST_MS;
    let connects = 0;
    while (now < 300_000) {
      connects += 1;
      now += 100;
      const lost = lostRetryDelay(delay, 100);
      if (bounded && lostRetryStep({ troubleForMs: now, upForMs: 100, waitMs: lost.wait }).kind === "stop") break;
      now += lost.wait;
      delay = lost.next;
    }
    return connects;
  };
  const before = run(false);
  const after = run(true);
  console.log(`connects in 5 min of a flapping daemon: before ${before}, after ${after}`);
  expect(after).toBeLessThan(before);
  expect(after).toBeLessThanOrEqual(20);
  // A connection that stayed up always reconnects, however long the trouble before it.
  expect(lostRetryStep({ troubleForMs: HOUR_MS, upForMs: CONNECTION_STABLE_MS, waitMs: 250 }).kind).toBe("retry");
});

test("a stopped pane asks again on the daemon's return, not on a tick", () => {
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
