import { expect, test } from "bun:test";
import {
  CloudComposeReservation,
  RESERVATION_IDLE_RELEASE_MS,
  RESERVATION_RENEW_MS,
  RESERVATION_RETRY_MS,
  RESERVATION_SEND_WAIT_MS,
  reservedCloudCall,
} from "./cloudComposeReservation";
import { cloudStartKeys, oneCloudStart } from "./cloudRun";
import { RELEASE_AFTER_MS } from "./newChatPrewarm";

function harness(reserve: () => Promise<unknown> = async () => ({})) {
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
    () => `compose-${++sequence}`,
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

test("a key the platform says is over is not retried: the next intent reserves with a new key", async () => {
  // The dev build of 2026-11-19: the first reserve got no answer in time, the platform's hold ran out, and each
  // retry of that key was refused `reservation.terminal`.
  const answers: (() => Promise<unknown>)[] = [
    () => Promise.reject({ code: "unavailable" }),
    () => Promise.reject({ code: "reservation.terminal" }),
    async () => ({}),
  ];
  const h = harness(() => answers.shift()!());
  h.reservation.selected();
  await settle();
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("x");
  await settle();
  expect(await h.reservation.ready("compose-1")).toBe(false);
  // Inside the gap after two failures in a row nothing goes out, old key or new.
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("xy");
  await settle();
  expect(h.calls).toHaveLength(2);
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("xyz");
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-2" }],
  ]);
  // The Send binds the new key's machine, and the ended key is never released: nothing of it is left.
  const request = { task: "xyz", reservationKey: h.reservation.handoff() };
  expect(await h.start(request, "send-1")).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual([
    "cloud.startChat",
    { task: "xyz", key: "send-1", reservationKey: "compose-2", gestureTicket: "ticket-1" },
  ]);
  expect(h.calls.some(([method]) => method === "cloud.releaseReservation")).toBe(false);
});

test("a new key's reserve waits for a reserve of the ended key that is still out", async () => {
  // The native pane takes one key at a time: a new key sent while the old key's reserve is out is refused.
  const out: { resolve: (value: unknown) => void; reject: (error: unknown) => void }[] = [];
  const h = harness(() => new Promise((resolve, reject) => out.push({ resolve, reject })));
  h.reservation.selected();
  await settle();
  out[0]!.reject({ code: "unavailable" });
  await settle();
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("x");
  await settle();
  // A second retry of the same key is queued behind the first, which then says the key is over.
  h.advance(RESERVATION_RETRY_MS);
  h.reservation.typed("xy");
  await settle();
  expect(h.calls).toHaveLength(2);
  out[1]!.reject({ code: "reservation.terminal" });
  await settle();
  expect(h.calls).toHaveLength(3);
  h.advance(RESERVATION_RETRY_MS * 2);
  h.reservation.typed("xyz");
  await settle();
  expect(h.calls).toHaveLength(3);
  out[2]!.reject({ code: "reservation.terminal" });
  await settle();
  expect(h.calls.map(([, params]) => params.composeKey)).toEqual(["compose-1", "compose-1", "compose-1", "compose-2"]);
  out[3]!.resolve({});
  expect(await h.reservation.ready("compose-2")).toBe(true);
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

// Composer journey run 43021965230: a Cloud start from a too-big folder was refused after it bound
// the compose's reservation; the next Send from the same page (no folder) named that reservation
// with its own start key and the platform refused it, "409 reservation.bound", in 3 s.
test("a reservation goes with one Send: its retry gets it again, another Send after it goes without", async () => {
  const h = harness();
  h.reservation.selected();
  await settle();
  expect(h.reservation.handoff(undefined, "send-1")).toBe("compose-1");
  // The start failed (the folder was too big); the person sends another prompt from the same page.
  h.reservation.selected();
  h.reservation.typed("hello");
  await settle();
  expect(h.reservation.handoff(undefined, "send-2")).toBeUndefined();
  const other = h.start({ task: "hello", home: true }, "send-2");
  expect(await other).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual(["cloud.startChat", { task: "hello", home: true, key: "send-2" }]);
  // A retry of the first Send (the same start key) still reaches the machine it bound.
  expect(h.reservation.handoff(undefined, "send-1")).toBe("compose-1");
  // No second reserve and no release: the bound reservation is the first Send's, released by nobody here.
  expect(h.calls.filter(([method]) => method === "cloud.reserve")).toHaveLength(1);
  expect(h.calls.filter(([method]) => method === "cloud.releaseReservation")).toEqual([]);
});

test("an empty local chat's compose names the chat it replaces on every reserve, and its Send binds that machine", async () => {
  const h = harness();
  h.reservation.selected("chat-1");
  h.advance(RESERVATION_RENEW_MS);
  h.reservation.typed("hello", "chat-1");
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1", replacesChat: "chat-1" }],
    ["cloud.reserve", { composeKey: "compose-1", replacesChat: "chat-1" }],
  ]);
  const request = { task: "hello", replacesChat: "chat-1", reservationKey: h.reservation.handoff() };
  expect(await h.start(request, "send-1")).toEqual({ ok: true });
  expect(h.calls.at(-1)).toEqual([
    "cloud.startChat",
    { task: "hello", replacesChat: "chat-1", key: "send-1", reservationKey: "compose-1", gestureTicket: "ticket-1" },
  ]);
});

test("a compose for another chat (a harness switch) gives the first chat's machine back and reserves its own", async () => {
  const h = harness();
  h.reservation.selected("chat-1");
  await settle();
  h.reservation.typed("hello", "chat-2");
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1", replacesChat: "chat-1" }],
    ["cloud.releaseReservation", { composeKey: "compose-1" }],
    ["cloud.reserve", { composeKey: "compose-2", replacesChat: "chat-2" }],
  ]);
  expect(h.reservation.handoff()).toBe("compose-2");
});

test("a Send refused before its reservation was bound gives the machine back, and the next Send names none", async () => {
  const h = harness();
  h.reservation.selected();
  await settle();
  const key = h.reservation.handoff();
  expect(key).toBe("compose-1");
  // Another key, or before any handoff, gives nothing back.
  h.reservation.returned("compose-9");
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.releaseReservation")).toEqual([]);
  h.reservation.returned(key!);
  h.reservation.returned(key!);
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.releaseReservation")).toEqual([
    ["cloud.releaseReservation", { composeKey: "compose-1" }],
  ]);
  expect(h.reservation.handoff()).toBeUndefined();
  // Picking Cloud again reserves a new machine for the next compose.
  h.reservation.selected();
  await settle();
  expect(h.calls.filter(([method]) => method === "cloud.reserve").at(-1)).toEqual([
    "cloud.reserve",
    { composeKey: "compose-2" },
  ]);
});

test("a composer that opens on Cloud leases at open, says atOpen until the first intent, and keeps its key", async () => {
  const h = harness();
  h.reservation.opened();
  h.reservation.opened();
  await settle();
  expect(h.calls).toEqual([["cloud.reserve", { composeKey: "compose-1", atOpen: true }]]);
  // The first key renews the same key as an ordinary compose, never a second machine.
  h.advance(RESERVATION_RENEW_MS);
  h.reservation.typed("hello");
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1", atOpen: true }],
    ["cloud.reserve", { composeKey: "compose-1" }],
  ]);
});

test("an open lease nobody types into is released at the idle bound", async () => {
  const h = harness();
  h.reservation.opened("chat-1");
  await settle();
  h.advance(RESERVATION_IDLE_RELEASE_MS);
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1", replacesChat: "chat-1", atOpen: true }],
    ["cloud.releaseReservation", { composeKey: "compose-1" }],
  ]);
});

test("an open lease the host refused (a hidden spare) asks again when the page opens again, then the key retries without atOpen", async () => {
  let refuse = true;
  const h = harness(async () => {
    if (refuse) throw { code: "gesture_required" };
    return {};
  });
  h.reservation.opened();
  await settle();
  refuse = false;
  h.reservation.opened();
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1", atOpen: true }],
    ["cloud.reserve", { composeKey: "compose-1", atOpen: true }],
  ]);
  expect(await h.reservation.ready(h.reservation.handoff()!)).toBe(true);
});

// Leo, 2026-11-25: "the new tab page. so when you select cloud/autocloud. that's when it can start."
test("picking Auto (AutoCloud) on the New Tab page leases one machine at the pick, and Auto deciding Cloud keeps that key for the Send", async () => {
  const h = harness();
  h.reservation.selected(undefined, false, true);
  await settle();
  expect(h.calls).toEqual([["cloud.reserve", { composeKey: "compose-1", auto: true }]]);
  // Auto decided Cloud (App.tsx applyRunMode("cloud")): the same compose, no second machine, and the Send takes it.
  h.reservation.selected(undefined);
  await settle();
  expect(h.calls).toHaveLength(1);
  const key = h.reservation.handoff();
  expect(key).toBe("compose-1");
  expect(await h.reservation.ready(key!)).toBe(true);
});

test("a New Tab page that opens with Auto remembered leases at open, and Auto deciding this Mac gives it back", async () => {
  const h = harness();
  h.reservation.opened(undefined, true);
  h.reservation.opened(undefined, true);
  await settle();
  expect(h.calls).toEqual([["cloud.reserve", { composeKey: "compose-1", atOpen: true, auto: true }]]);
  h.reservation.abandon();
  await settle();
  expect(h.calls).toEqual([
    ["cloud.reserve", { composeKey: "compose-1", atOpen: true, auto: true }],
    ["cloud.releaseReservation", { composeKey: "compose-1" }],
  ]);
});
