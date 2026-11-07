// The relaunch-reconnect bench (scripts/cmux-next/bench_relaunch_reconnect.py) reads each page's
// connect path on the wall clock: the first time of each mark, and the first event of the shown
// chat that arrives live (within LIVE_EVENT_LAG_MS of when acpmux recorded it), past any backlog.
import { expect, test } from "bun:test";
import { AcpmuxPerf, LIVE_EVENT_LAG_MS } from "../src/agent-session/acpmux/perf";

test("a page's launch marks keep their first time; a retried handshake counts but keeps the first start", () => {
  const perf = new AcpmuxPerf();
  perf.markLaunch("handshakeStart", 1_000);
  perf.markLaunch("handshakeStart", 3_000);
  perf.markLaunch("handshakeReady", 3_500);
  perf.markLaunch("connectStart", 3_600);
  perf.markLaunch("connected", 3_900);
  const timeline = perf.launchTimeline();
  expect(timeline.handshake_attempts).toBe(2);
  expect(timeline.handshakeStart_epoch_ms).toBe(1_000);
  expect(timeline.handshakeReady_epoch_ms).toBe(3_500);
  expect(timeline.connectStart_epoch_ms).toBe(3_600);
  expect(timeline.connected_epoch_ms).toBe(3_900);
  expect(timeline.liveEvent_epoch_ms).toBeUndefined();
});

test("backlog events are the first event; the first that arrives within the lag is the live one", () => {
  const perf = new AcpmuxPerf();
  // Replayed backlog: recorded long before it arrives.
  perf.markEvent(10_000, 20_000);
  perf.markEvent(11_000, 20_010);
  // No recorded time: never live.
  perf.markEvent(undefined, 20_020);
  expect(perf.launchTimeline().firstEvent_epoch_ms).toBe(20_000);
  expect(perf.launchTimeline().liveEvent_epoch_ms).toBeUndefined();
  perf.markEvent(20_100 - LIVE_EVENT_LAG_MS + 50, 20_100);
  perf.markEvent(20_190, 20_200);
  const timeline = perf.launchTimeline();
  expect(timeline.firstEvent_epoch_ms).toBe(20_000);
  expect(timeline.liveEvent_epoch_ms).toBe(20_100);
});
