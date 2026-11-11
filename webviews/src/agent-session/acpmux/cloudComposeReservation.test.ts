import { expect, test } from "bun:test";
import {
  CloudComposeReservation,
  RESERVATION_IDLE_RELEASE_MS,
  RESERVATION_RENEW_MS,
  RESERVATION_RETRY_MS,
  RESERVATION_SEND_WAIT_MS,
  reservedCloudCall,
} from "./cloudComposeReservation";
import { cloudStartKeys, oneCloudStart, type CloudStartKeyStore } from "./cloudRun";
import { RELEASE_AFTER_MS } from "./newChatPrewarm";

function harness(
  reserve: () => Promise<unknown> = async () => ({}),
  store: CloudStartKeyStore | undefined = undefined,
  prefix = "compose",
) {
  const calls: [string, Record<string, unknown>][] = [];
  const timers: { run: () => void; live: boolean; at: number; ms: number }[] = [];
  let sequence = 0;
  let now = 0;
  const call = async (method: string, params: Record<string, unknown>) => {
    calls.push([method, params]);
    if (method === "transport.gesture") return { ticket: "ticket-1" };
    return method === "cloud.reserve" ? reserve() : {};
  };
  const reservation = new CloudComposeReservation(
    call,
    {
      now: () => now,
      schedule(run, ms) {
        // The cleared-prompt grace, the Send's wait, and the idle release (its first wait, or what is left of it).
        expect(
          [RELEASE_AFTER_MS, RESERVATION_SEND_WAIT_MS].includes(ms) || (ms > 0 && ms <= RESERVATION_IDLE_RELEASE_MS),
        ).toBe(true);
        const timer = { run, live: true, at: now + ms, ms };
        timers.push(timer);
        return () => (timer.live = false);
      },
    },
    () => `${prefix}-${++sequence}`,
    store,
  );
  return {
    reservation,
    calls,
    start: oneCloudStart(reservedCloudCall(call, reservation)),
    /// Runs the live timers of `ms` now (default: the cleared-prompt grace).
    expire(ms: number = RELEASE_AFTER_MS) {
      for (const timer of timers) {
        if (!timer.live || timer.ms !== ms) continue;
        timer.live = false;
        timer.run();
      }
    },
    /// Moves the clock on by `ms`, running every timer that came due on the way.
    advance(ms: number) {
      const until = now + ms;
      for (;;) {
        const due = timers.filter((timer) => timer.live && timer.at <= until).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        now = due.at;
        due.live = false;
        due.run();
      }
      now = until;
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

test("Send waits for a slow reserve only briefly: the start goes without it, and the late reservation is released once", async () => {
  // Leo, 2026-11-09: "it seems like it's not actually properly starting": a reserve the platform
  // held for up to 125 s held the Send, with nothing in the log, the whole time.
  let ready!: () => void;
  const h = harness(() => new Promise<void>((resolve) => (ready = resolve)));
  h.reservation.selected();
  const sent = h.start({ task: "hello", home: true, reservationKey: h.reservation.handoff() }, "send-1");
  await settle();
  expect(h.calls.map(([method]) => method)).toEqual(["transport.gesture", "cloud.reserve"]);
  h.expire(RESERVATION_SEND_WAIT_MS);
  expect(await sent).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual([
    "cloud.startChat",
    { task: "hello", home: true, key: "send-1", gestureTicket: "ticket-1" },
  ]);
  // Nothing is released while the reserve is out: a DELETE before its create would leak the machine.
  expect(h.calls.map(([method]) => method)).not.toContain("cloud.releaseReservation");
  ready();
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.releaseReservation")).toEqual([
    ["cloud.releaseReservation", { composeKey: "compose-1" }],
  ]);
  // The next compose reserves afresh; the late one is never handed off again.
  h.reservation.selected();
  await settle();
  expect(h.reservation.handoff()).toBe("compose-2");
});

test("a reserve that answers within the wait is still used, and its wait timer is cleared", async () => {
  let ready!: () => void;
  const h = harness(() => new Promise<void>((resolve) => (ready = resolve)));
  h.reservation.selected();
  const sent = h.start({ task: "quick", reservationKey: h.reservation.handoff() }, "send-1");
  await settle();
  ready();
  expect(await sent).toEqual({ ok: true });
  h.expire(RESERVATION_SEND_WAIT_MS);
  await settle();
  expect(h.calls.at(-1)).toEqual([
    "cloud.startChat",
    { task: "quick", key: "send-1", reservationKey: "compose-1", gestureTicket: "ticket-1" },
  ]);
  expect(h.calls.map(([method]) => method)).not.toContain("cloud.releaseReservation");
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

const memoryStore = (): CloudStartKeyStore => {
  const items = new Map<string, string>();
  return { getItem: (name) => items.get(name) ?? null, setItem: (name, value) => void items.set(name, value) };
};
const startChats = (calls: [string, Record<string, unknown>][]) =>
  calls.filter(([method]) => method === "cloud.startChat").map(([, params]) => params);

// The platform binds a compose to one Send and a Send to one compose, and answers anything else
// 409 reservation.bound: "Couldn't move the chat" on a start that had done nothing wrong.
test("a new prompt after a failed start does not name the reservation an earlier Send bound", async () => {
  const h = harness();
  h.reservation.selected();
  await h.start({ task: "first", reservationKey: h.reservation.handoff() }, "send-1");
  await h.start({ task: "1+1", reservationKey: h.reservation.handoff() }, "send-2");
  const [first, second] = startChats(h.calls);
  expect(first?.reservationKey).toBe("compose-1");
  expect(second?.key).toBe("send-2");
  expect(second).not.toHaveProperty("reservationKey");
  expect(second?.gestureTicket).toBe("ticket-1");
});

test("a retry of the same Send keeps its reservation, so it reaches the machine it bound", async () => {
  const h = harness();
  h.reservation.selected();
  await h.start({ task: "hello", reservationKey: h.reservation.handoff() }, "send-1");
  await h.start({ task: "hello", reservationKey: h.reservation.handoff() }, "send-1");
  expect(startChats(h.calls).map((params) => params.reservationKey)).toEqual(["compose-1", "compose-1"]);
});

test("a Send kept across pages does not bind a second compose, and that compose goes back", async () => {
  const store = memoryStore();
  const before = harness(undefined, store, "before");
  before.reservation.selected();
  await before.start({ task: "1+1", reservationKey: before.reservation.handoff() }, "send-1");
  const after = harness(undefined, store, "after");
  after.reservation.selected();
  await after.start({ task: "1+1", reservationKey: after.reservation.handoff() }, "send-1");
  await settle();
  expect(startChats(after.calls)[0]).not.toHaveProperty("reservationKey");
  expect(after.calls).toContainEqual(["cloud.releaseReservation", { composeKey: "after-1" }]);
});

test("a later environment pick releases the default-image reservation", async () => {
  const h = harness();
  h.reservation.selected();
  expect(h.reservation.handoff("env_project")).toBeUndefined();
  await settle();
  expect(h.calls.map(([method]) => method)).toEqual(["cloud.reserve", "cloud.releaseReservation"]);
});

// Leo, 2026-11-09: "pre-setting up stuff as a user selected cloud and was starting to type ... at least
// frontload the stuff that we can check earlier".
test("typing renews the compose's hold with the same key, at most once per RESERVATION_RENEW_MS", async () => {
  const h = harness();
  h.reservation.selected();
  h.advance(RESERVATION_RENEW_MS - 1);
  h.reservation.typed("h");
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.reserve")).toHaveLength(1);
  h.advance(1);
  h.reservation.typed("he");
  h.reservation.typed("hel");
  await settle();
  h.advance(RESERVATION_RENEW_MS);
  h.reservation.typed("hello");
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-1" }],
  ]);
  // The Send still hands off the one compose key.
  expect(h.reservation.handoff()).toBe("compose-1");
  h.advance(RESERVATION_RENEW_MS);
  h.reservation.typed("hello again");
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.reserve")).toHaveLength(3);
});

test("a reserve that failed (Cloud remembered on load, no gesture) is tried again on the next keystroke, same key", async () => {
  let fail = true;
  const h = harness(async () => {
    if (fail) throw new Error("gesture_required");
    return {};
  });
  h.reservation.selected();
  await settle();
  expect(await h.reservation.ready("compose-1")).toBe(false);
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("x");
  await settle();
  // Two failures in a row: the next try waits twice as long.
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("xy");
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.reserve")).toHaveLength(2);
  h.advance(RESERVATION_RETRY_MS);
  fail = false;
  h.reservation.typed("xyz");
  await settle();
  expect(await h.reservation.ready("compose-1")).toBe(true);
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-1" }],
  ]);
});

test("a renewal that failed keeps the Send off the key: it goes as an ordinary one", async () => {
  let fail = false;
  const h = harness(async () => {
    if (fail) throw new Error("unavailable");
    return {};
  });
  h.reservation.typed("x");
  await settle();
  h.advance(RESERVATION_RENEW_MS);
  fail = true;
  h.reservation.typed("xy");
  const request = { task: "xy", reservationKey: h.reservation.handoff() };
  expect(await h.start(request, "send-1")).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual(["cloud.startChat", { task: "xy", key: "send-1", gestureTicket: "ticket-1" }]);
});

test("no intent for RESERVATION_IDLE_RELEASE_MS releases the compose's machine; typing moves that on", async () => {
  const h = harness();
  h.reservation.selected();
  h.advance(RESERVATION_IDLE_RELEASE_MS - 60_000);
  h.reservation.typed("still writing");
  h.advance(RESERVATION_IDLE_RELEASE_MS - 1);
  await settle();
  expect(h.calls.map(([method]) => method)).not.toContain("cloud.releaseReservation");
  h.advance(1);
  await settle();
  expect(h.calls.at(-1)).toEqual(["cloud.releaseReservation", { composeKey: "compose-1" }]);
  // The next intent is a new compose.
  h.reservation.typed("back");
  await settle();
  expect(h.calls.at(-1)).toEqual(["cloud.reserve", { composeKey: "compose-2" }]);
});

test("a sent compose is never released by the idle timer nor renewed", async () => {
  const h = harness();
  h.reservation.selected();
  await settle();
  expect(h.reservation.handoff()).toBe("compose-1");
  h.advance(RESERVATION_IDLE_RELEASE_MS * 2);
  h.reservation.typed("after send");
  await settle();
  expect(h.calls).toEqual([["cloud.reserve", { composeKey: "compose-1" }]]);
});

test("a Send during a slow renewal waits at most RESERVATION_SEND_WAIT_MS; the idle timer never releases it", async () => {
  let slow = false;
  const h = harness(() => (slow ? new Promise(() => undefined) : Promise.resolve({})));
  h.reservation.typed("x");
  await settle();
  h.advance(RESERVATION_RENEW_MS);
  slow = true;
  h.reservation.typed("xy");
  const sent = h.start({ task: "xy", reservationKey: h.reservation.handoff() }, "send-1");
  await settle();
  h.expire(RESERVATION_SEND_WAIT_MS);
  expect(await sent).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual(["cloud.startChat", { task: "xy", key: "send-1", gestureTicket: "ticket-1" }]);
  h.advance(RESERVATION_IDLE_RELEASE_MS * 2);
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.releaseReservation")).toEqual([]);
});

test("a reserve the platform refuses for the team's plan never holds the Send: it goes at once, without the reservation", async () => {
  const h = harness(() => Promise.reject({ code: "cloud.plan.required" }));
  h.reservation.selected();
  await settle();
  const key = h.reservation.handoff();
  const answer = h.start(
    { task: "fix it", ...(key ? { reservationKey: key } : {}) },
    "6f1c3a52-6c5e-4c38-9b3e-6b1d2a3c4d5e",
  );
  await settle();
  // No timer had to run: the refusal answered, so the start went without waiting out the bound.
  const sent = h.calls.find(([method]) => method === "cloud.startChat");
  expect(sent?.[1].reservationKey).toBeUndefined();
  expect(await answer).toEqual({ ok: true });
});
