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
  hostSelfRetrying,
  lostRetryDelay,
  nextRetryDelay,
  SELF_RETRY_SAID_MS,
  troubleSinceAfterLoss,
  QUICK_RETRY_WINDOW_MS,
  quickRetry,
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
  expect(hostIsReconnecting({ code: "cmux.page.failed", retryable: false })).toBe(true);
  expect(hostIsReconnecting({ code: "native.failed", retryable: false })).toBe(true);
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

test("a recovering pane asks again within 2 s; a refusal keeps retrying, at least every 30 s", () => {
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
  expect(waits(false)).toEqual([250, 500, 1000, 2000, 4000, 8000, 16_000, 30_000]);
});

// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up and load
// faster/percievably load faster / whatever it takes". A chat on screen whose acpmux restarts asks
// again within half a second for the first 10 s (a restart's usual length), so it is back within
// 500 ms of acpmux answering instead of up to 2 s later. A hidden chat, or a recovery past 10 s,
// keeps the 2 s step; a refusal keeps its 30 s one.
test("a shown chat asks again within 500 ms during the first 10 s of a recovery", () => {
  const waits = (quick: boolean, recovering = true) => {
    let delay = 250;
    const out: number[] = [];
    for (let attempt = 0; attempt < 8; attempt++) {
      out.push(delay);
      delay = nextRetryDelay(delay, recovering, quick);
    }
    return out;
  };
  expect(waits(true)).toEqual([250, 500, 500, 500, 500, 500, 500, 500]);
  expect(waits(false)).toEqual([250, 500, 1000, 2000, 2000, 2000, 2000, 2000]);
  expect(waits(true, false)).toEqual([250, 500, 1000, 2000, 4000, 8000, 16_000, 30_000]);
  expect(QUICK_RETRY_WINDOW_MS).toBe(10_000);
  expect(quickRetry({ shown: true, failingForMs: 9_999 })).toBe(true);
  expect(quickRetry({ shown: true, failingForMs: 10_000 })).toBe(false);
  expect(quickRetry({ shown: false, failingForMs: 0 })).toBe(false);
});

// The first-load bench's 10 s drop got slower with quick asks (791 -> 2618 ms): over a page's own
// WebSocket, Chromium holds back each open by 1-5 s once ~15 have failed, so ~25 refused opens in
// 10 s delayed the one that would succeed. Only the app's host connect (`acpmux-bridge`) asks quickly.
test("a page that opens its own WebSocket keeps the 2 s step", () => {
  expect(quickRetry({ shown: true, failingForMs: 0, browserSocket: false })).toBe(true);
  expect(quickRetry({ shown: true, failingForMs: 0, browserSocket: true })).toBe(false);
});

// Leo, 2026-11-12, after the machine hosting a chat's agent rebooted: "it should just automatically
// do stuff". A failure the pane clears by asking again is the quiet line; one that waits on the
// person, or that asking cannot change, keeps its words and action.
test("only a failure the pane clears by asking again is self-retrying", () => {
  expect(hostSelfRetrying(new Error("Couldn't connect to the agent."), false)).toBe(true);
  expect(hostSelfRetrying({ code: "native.not_connected" }, false)).toBe(true);
  expect(hostSelfRetrying({ code: "native.timed_out" }, false)).toBe(true);
  expect(hostSelfRetrying({ code: "host_unavailable", details: { reconnecting: true } }, false)).toBe(true);
  expect(hostSelfRetrying({ code: "host_unavailable" }, false)).toBe(false);
  expect(hostSelfRetrying({ code: "agent_session.untrusted" }, false)).toBe(false);
  expect(hostSelfRetrying({ code: -32000, reason: "message.too_large" }, false)).toBe(false);
  expect(hostSelfRetrying(new Error("Couldn't connect to the agent."), true)).toBe(false);
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

// Leo, 2026-11-23: "im getting an infinite Reconnecting... thing with claude-sr2-coord-old". A chat
// that never opens (its attach never answers, or the daemon drops the pane right after every
// connect) was a bare "Reconnecting…" forever: no reason, no Details, no Retry. The loop below is the
// pane's own (App.tsx): each connect clears `failingSince`, so only the trouble clock, which a
// connection lost within CONNECTION_STABLE_MS does not end, can bound it.
test("a chat that never stays open stops being a bare Reconnecting… past the bound", () => {
  const timedOut = { code: "native.timed_out" };
  let now = 0;
  let troubleSince: number | undefined;
  let connectedAt = 0;
  let delay = 250;
  const said: boolean[] = [];
  // A handshake that fails (the attach never answered), then a connect lost 3 s later, over and over.
  while (now < 4 * 60_000) {
    troubleSince ??= now; // the handshake catch
    said.push(!hostSelfRetrying(timedOut, false, now - troubleSince));
    now += 2_000;
    connectedAt = now; // a connect
    now += 3_000; // lost soon after
    troubleSince = troubleSinceAfterLoss(troubleSince, now - connectedAt, now);
    const lost = lostRetryDelay(delay, now - connectedAt);
    delay = lost.next;
    now += lost.wait;
    said.push(!hostSelfRetrying(timedOut, false, now - troubleSince));
  }
  const firstSaid = said.indexOf(true);
  expect(firstSaid).toBeGreaterThan(0);
  // Quiet for the usual recovery, then said, and said from then on.
  expect(said.slice(firstSaid).every(Boolean)).toBe(true);
  expect(troubleSince).toBe(0);
});

test("the usual recovery stays quiet, and a connection that stayed up starts the trouble over", () => {
  const lostLink = new Error("Couldn't connect to the agent.");
  expect(hostSelfRetrying(lostLink, false, 0)).toBe(true);
  expect(hostSelfRetrying(lostLink, false, SELF_RETRY_SAID_MS - 1)).toBe(true);
  expect(hostSelfRetrying(lostLink, false, SELF_RETRY_SAID_MS)).toBe(false);
  // A refusal that waits on the person is said at once, bound or not.
  expect(hostSelfRetrying({ code: "host_unavailable" }, false, 0)).toBe(false);
  // Lost after a minute up: a new trouble, starting now; lost after a second: the old one goes on.
  expect(troubleSinceAfterLoss(5_000, 60_000, 200_000)).toBe(200_000);
  expect(troubleSinceAfterLoss(5_000, 1_000, 200_000)).toBe(5_000);
  expect(troubleSinceAfterLoss(undefined, 1_000, 200_000)).toBe(200_000);
});
