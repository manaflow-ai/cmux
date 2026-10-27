// A refused handshake offers Restart acpmux only when the host says so (another binary's acpmux
// holds this app's socket and the app may replace it). While the restart runs, no handshake
// starts, including a Retry queued behind an attempt in flight; when it ends, the pane asks once.
import { expect, test } from "bun:test";
import { AcpmuxRestartGate, offersAcpmuxRestart } from "./hostRetry";

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
