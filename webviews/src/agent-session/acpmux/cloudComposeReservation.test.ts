import { expect, test } from "bun:test";
import { CloudComposeReservation, reservedCloudCall } from "./cloudComposeReservation";
import { cloudStartKeys, oneCloudStart } from "./cloudRun";
import { RELEASE_AFTER_MS } from "./newChatPrewarm";

function harness(reserve: () => Promise<unknown> = async () => ({})) {
  const calls: [string, Record<string, unknown>][] = [];
  const timers: { run: () => void; live: boolean }[] = [];
  let sequence = 0;
  const call = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "transport.gesture") return { ticket: "ticket-1" };
    return method === "cloud.reserve" ? reserve() : {};
  };
  const reservation = new CloudComposeReservation(
    call,
    {
      now: () => 0,
      schedule(run, ms) {
        expect(ms).toBe(RELEASE_AFTER_MS);
        const timer = { run, live: true };
        timers.push(timer);
        return () => (timer.live = false);
      },
    },
    () => `compose-${++sequence}`,
  );
  return {
    reservation,
    calls,
    start: oneCloudStart(reservedCloudCall(call, reservation)),
    expire() {
      for (const timer of timers) {
        if (!timer.live) continue;
        timer.live = false;
        timer.run();
      }
    },
  };
}

const settle = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve();
};

test("Cloud selection and every typed character reserve once per compose", async () => {
  const h = harness();
  h.reservation.selected();
  h.reservation.typed("h");
  h.reservation.typed("hello");
  h.reservation.selected();
  await settle();
  expect(h.calls).toEqual([["cloud.reserve", { composeKey: "compose-1" }]]);
  h.reservation.reset();
  h.reservation.typed("next chat");
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.reserve")).toEqual([
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-2" }],
  ]);
});

test("first character with Cloud selected reserves; whitespace does not", async () => {
  const h = harness();
  h.reservation.typed("   ");
  await settle();
  expect(h.calls).toEqual([]);
  h.reservation.typed("x");
  await settle();
  expect(h.calls).toEqual([["cloud.reserve", { composeKey: "compose-1" }]]);
});

test("Send reserves its native gesture before a slow reserve, ignores a second Return, and page close cannot release its lease", async () => {
  let ready!: () => void;
  const h = harness(() => new Promise<void>((resolve) => (ready = resolve)));
  h.reservation.selected();
  const request = { task: "reply PONG", home: true, reservationKey: h.reservation.handoff() };
  const sent = h.start(request, "send-1");
  expect(h.start(request, "send-1")).toBeUndefined();
  h.reservation.abandon();
  await settle();
  expect(h.calls).toEqual([
    ["transport.gesture", { intent: { method: "cloud.startChat", params: { key: "send-1" } } }],
    ["cloud.reserve", { composeKey: "compose-1" }],
  ]);
  ready();
  expect(await sent).toEqual({ ok: true });
  expect(h.calls).toEqual([
    ["transport.gesture", { intent: { method: "cloud.startChat", params: { key: "send-1" } } }],
    ["cloud.reserve", { composeKey: "compose-1" }],
    [
      "cloud.startChat",
      {
        task: "reply PONG",
        home: true,
        key: "send-1",
        reservationKey: "compose-1",
        gestureTicket: "ticket-1",
      },
    ],
  ]);
});

test("a failed speculative request falls back to an ordinary Send without retrying reserve", async () => {
  const h = harness(async () => {
    throw new Error("not available");
  });
  h.reservation.typed("hello");
  const request = { task: "hello", reservationKey: h.reservation.handoff() };
  expect(await h.start(request, "send-1")).toEqual({ ok: true });
  h.reservation.typed("hello again");
  await settle();
  expect(h.calls).toEqual([
    ["transport.gesture", { intent: { method: "cloud.startChat", params: { key: "send-1" } } }],
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.startChat", { task: "hello", key: "send-1", gestureTicket: "ticket-1" }],
  ]);
});

test("a reservation that settles after the live 30-second gesture still reaches Cloud with authorization", async () => {
  let settleReserve!: () => void;
  const h = harness(() => new Promise<void>((resolve) => (settleReserve = resolve)));
  h.reservation.selected();
  const sent = h.start({ task: "slow warm", reservationKey: h.reservation.handoff() }, "send-slow");
  await settle();
  // The native ticket was reserved before the allocation wait. A real platform response can
  // arrive after the ordinary 30-second gesture has expired without yielding gesture_required.
  expect(h.calls).toContainEqual([
    "transport.gesture",
    { intent: { method: "cloud.startChat", params: { key: "send-slow" } } },
  ]);
  settleReserve();
  expect(await sent).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual([
    "cloud.startChat",
    { task: "slow warm", key: "send-slow", reservationKey: "compose-1", gestureTicket: "ticket-1" },
  ]);
});

test("abandon while reserve is in flight releases after allocation, only once", async () => {
  let ready!: () => void;
  const h = harness(() => new Promise<void>((resolve) => (ready = resolve)));
  h.reservation.selected();
  h.reservation.abandon();
  h.reservation.abandon();
  await settle();
  expect(h.calls.map(([method]) => method)).toEqual(["cloud.reserve"]);
  ready();
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.releaseReservation", { composeKey: "compose-1" }],
  ]);
  h.reservation.selected();
  await settle();
  expect(h.reservation.handoff()).toBe("compose-2");
  expect(h.calls.map(([method]) => method)).toEqual(["cloud.reserve", "cloud.releaseReservation", "cloud.reserve"]);
});

test("clearing releases after the short grace period; retyping cancels the timer", async () => {
  const h = harness();
  h.reservation.typed("x");
  h.reservation.typed("");
  h.reservation.typed("y");
  h.expire();
  await settle();
  expect(h.calls.map(([method]) => method)).toEqual(["cloud.reserve"]);
  h.reservation.typed("");
  h.expire();
  await settle();
  expect(h.calls.map(([method]) => method)).toEqual(["cloud.reserve", "cloud.releaseReservation"]);
});

test("the reservation is transport detail: an uncertain Send keeps its original send key", () => {
  const keys = cloudStartKeys(
    undefined,
    () => 0,
    () => "send-1",
  );
  const request = { task: "hello", reservationKey: "compose-1" };
  expect(keys.keyFor(request)).toBe("send-1");
  keys.ended(request, { ok: false, code: "unavailable" });
  expect(keys.keyFor({ task: "hello", reservationKey: "compose-2" })).toBe("send-1");
});

test("a later environment pick releases the default-image reservation", async () => {
  const h = harness();
  h.reservation.selected();
  expect(h.reservation.handoff("env_project")).toBeUndefined();
  await settle();
  expect(h.calls.map(([method]) => method)).toEqual(["cloud.reserve", "cloud.releaseReservation"]);
});
