// A refused handshake offers Restart acpmux only when the host says so (another binary's acpmux
// holds this app's socket and the app may replace it). While the restart runs, no handshake
// starts, including a Retry queued behind an attempt in flight; when it ends, the pane asks once.
import { expect, test } from "bun:test";
import {
  AcpmuxRestartGate,
  HOST_ERROR_DEADLINE_MS,
  hostErrorShows,
  hostIsReconnecting,
  hostRefusedTooLarge,
  nextRetryDelay,
  offersAcpmuxRestart,
} from "./hostRetry";

test("only a typed recovery or an unclassified lost transport is neutral", () => {
  expect(hostIsReconnecting({ code: "host_unavailable", details: { reconnecting: true }, retryable: false })).toBe(
    true,
  );
  expect(hostIsReconnecting({ code: "host_unavailable" })).toBe(false);
  expect(hostIsReconnecting({ code: "host_unavailable", details: { restartAcpmux: true } })).toBe(false);
  expect(hostIsReconnecting({ code: "agent_session.untrusted" })).toBe(false);
  expect(hostIsReconnecting({ code: "native.invalid_request" })).toBe(false);
  expect(hostIsReconnecting({ code: "native.not_connected" })).toBe(true);
  expect(hostIsReconnecting({ code: "native.not_connected", retryable: false })).toBe(true);
  expect(hostIsReconnecting({ code: "native.timed_out" })).toBe(true);
  expect(hostIsReconnecting({ code: "known", retryable: true })).toBe(true);
  expect(hostIsReconnecting({ code: "known", retryable: false })).toBe(false);
  expect(hostIsReconnecting(new Error("socket closed"))).toBe(true);
});

test("only a refusal the host marked restartAcpmux offers Restart acpmux", () => {
  expect(offersAcpmuxRestart({ code: "host_unavailable", details: { restartAcpmux: true } })).toBe(true);
  expect(offersAcpmuxRestart({ code: "host_unavailable", details: { machineName: "mini" } })).toBe(false);
  expect(offersAcpmuxRestart({ code: "host_unavailable", details: { restartAcpmux: "yes" } })).toBe(false);
  expect(offersAcpmuxRestart({ code: "host_unavailable" })).toBe(false);
  expect(offersAcpmuxRestart(null)).toBe(false);
  expect(offersAcpmuxRestart("refused")).toBe(false);
});

/// The pane's loop as App.tsx runs it: an attempt in flight, a Retry queued behind it, an
/// automatic retry scheduled after a failure or a lost daemon; `connectHost` itself asks the gate.
function paneLoop(gate: AcpmuxRestartGate) {
  const log: string[] = [];
  let retryPending = false;
  let timer = false;
  let connected = false;
  const connectHost = (why: string) => {
    if (gate.mayAsk()) log.push(`handshake (${why})`);
  };
  return {
    log,
    queueRetry: () => (retryPending = true),
    /// The attempt in flight ends with a refusal: App.tsx's catch, then its finally.
    failAttempt: () => {
      if (gate.mayAsk()) timer = true;
      if (retryPending) {
        retryPending = false;
        if (!connected && gate.mayAsk()) connectHost("queued Retry");
      }
    },
    /// The daemon's connection closed: App.tsx schedules a reconnect.
    lose: () => {
      connected = false;
      timer = true;
    },
    scheduleTimer: () => (timer = true),
    fireTimer: () => {
      if (timer) connectHost("automatic");
      timer = false;
    },
    connect: () => (connected = true),
    hooks: {
      cancelRetries: () => {
        timer = false;
        retryPending = false;
      },
      changed: (restarting: boolean) => log.push(restarting ? "restarting" : "restarted"),
      connected: () => connected,
      ask: () => log.push("handshake (after restart)"),
    },
  };
}

test("a Retry queued before Restart acpmux never asks the old daemon while it shuts down", async () => {
  const gate = new AcpmuxRestartGate();
  const loop = paneLoop(gate);
  loop.queueRetry();
  let finishStop!: () => void;
  const restart = gate.run(() => new Promise<void>((resolve) => (finishStop = resolve)), loop.hooks);
  // The attempt that was in flight fails while the daemon is still stopping.
  loop.failAttempt();
  loop.fireTimer();
  expect(gate.mayAsk()).toBe(false);
  expect(loop.log).toEqual(["restarting"]);
  finishStop();
  await restart;
  expect(loop.log).toEqual(["restarting", "restarted", "handshake (after restart)"]);
  expect(gate.mayAsk()).toBe(true);
});

test("a retry timer that fires, or a daemon lost, while Restart acpmux runs asks nothing", async () => {
  const gate = new AcpmuxRestartGate();
  const loop = paneLoop(gate);
  let finishStop!: () => void;
  const restart = gate.run(() => new Promise<void>((resolve) => (finishStop = resolve)), loop.hooks);
  // A timer callback already queued when the restart cleared the timer, then a lost connection.
  loop.scheduleTimer();
  loop.fireTimer();
  loop.lose();
  loop.fireTimer();
  expect(loop.log).toEqual(["restarting"]);
  finishStop();
  await restart;
  expect(loop.log).toEqual(["restarting", "restarted", "handshake (after restart)"]);
});

test("a second click while Restart acpmux runs does nothing; a client that connected meanwhile needs no handshake", async () => {
  const gate = new AcpmuxRestartGate();
  const loop = paneLoop(gate);
  let stops = 0;
  let finishStop!: () => void;
  const first = gate.run(() => {
    stops += 1;
    return new Promise<void>((resolve) => (finishStop = resolve));
  }, loop.hooks);
  await gate.run(async () => void (stops += 1), loop.hooks);
  expect(stops).toBe(1);
  loop.connect();
  finishStop();
  await first;
  expect(loop.log).toEqual(["restarting", "restarted"]);
});

test("a failed restart still asks again once", async () => {
  const gate = new AcpmuxRestartGate();
  const loop = paneLoop(gate);
  await gate.run(() => Promise.reject(new Error("native.failed")), loop.hooks);
  expect(loop.log).toEqual(["restarting", "restarted", "handshake (after restart)"]);
});

const restarting = { code: "host_unavailable", details: { reconnecting: true } };

test("a recovering host shows nothing within the deadline, then one line", () => {
  // Within the deadline a transient failure renders no card, no spinner and no button.
  expect(hostErrorShows(restarting, 0)).toBe(false);
  expect(hostErrorShows(restarting, HOST_ERROR_DEADLINE_MS - 1)).toBe(false);
  expect(hostErrorShows({ code: "native.timed_out" }, 10_000)).toBe(false);
  // Past it the failure is said.
  expect(hostErrorShows(restarting, HOST_ERROR_DEADLINE_MS)).toBe(true);
  // The deadline is a real one: about 20-30 s of failed attempts, not a minute.
  expect(HOST_ERROR_DEADLINE_MS).toBeGreaterThanOrEqual(20_000);
  expect(HOST_ERROR_DEADLINE_MS).toBeLessThanOrEqual(30_000);
});

test("a hard refusal is said at once", () => {
  // acpmux missing, another build's daemon (Restart acpmux), a refused chat of another machine.
  expect(hostErrorShows({ code: "host_unavailable" }, 0)).toBe(true);
  expect(hostErrorShows({ code: "host_unavailable", details: { restartAcpmux: true } }, 0)).toBe(true);
  expect(hostErrorShows({ code: "agent_session.untrusted" }, 0)).toBe(true);
});

test("a recovering pane asks again within 2 s; a refusal backs off to 30 s", () => {
  const waits = (recovering: boolean) => {
    let delay = 250;
    const out: number[] = [];
    for (let attempt = 0; attempt < 8; attempt++) {
      out.push(delay);
      delay = nextRetryDelay(delay, recovering);
    }
    return out;
  };
  expect(waits(true)).toEqual([250, 500, 1000, 2000, 2000, 2000, 2000, 2000]);
  expect(Math.max(...waits(false))).toBe(30_000);
});

/// A chat whose open reply passes one message is refused the same way at every ask (Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size"): the pane stops asking on its own.
test("a handshake refused as message.too_large is told apart from every other refusal", () => {
  const tooLarge = { code: -32000, reason: "message.too_large", message: "message too large to send: 16907300 bytes" };
  expect(hostRefusedTooLarge(tooLarge)).toBe(true);
  // Said at once, as any refusal: no waiting out the recovery deadline first.
  expect(hostErrorShows(tooLarge, 0)).toBe(true);
  expect(hostRefusedTooLarge({ code: "native.timed_out" })).toBe(false);
  expect(hostRefusedTooLarge({ code: -32000, reason: "trust.pending" })).toBe(false);
  expect(hostRefusedTooLarge(new Error("message too large to send"))).toBe(false);
  expect(hostRefusedTooLarge(null)).toBe(false);
});
