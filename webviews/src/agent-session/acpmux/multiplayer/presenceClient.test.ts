import { expect, jest, test } from "bun:test";
import { PresenceClient, STOP_RETRIES, STOP_RETRY_MS, TYPING_IDLE_MS, TYPING_REFRESH_MS } from "./presenceClient";

const ana = { id: "tailnet:ana@example.com", name: "Ana", devices: 1, viewing: true, typing: false };
const me = { id: "owner", name: "Leo", devices: 1, viewing: true, typing: false };

function client() {
  const sent: { sessionId: string; on: boolean }[] = [];
  let changes = 0;
  let clock = 1_000;
  const presence = new PresenceClient(
    (_method, params) => {
      sent.push(params);
    },
    () => (changes += 1),
    () => "owner",
    () => clock,
  );
  return { presence, sent, changes: () => changes, tick: (ms: number) => (clock += ms) };
}

test("an acpmux without presence gets no typing and shows nobody", () => {
  const { presence, sent } = client();
  presence.attached("s1", { events: [] });
  presence.typed("hello");
  expect(sent).toEqual([]);
  expect(presence.presenceOf("s1")).toBeUndefined();
});

test("the attach reply and notifications show the others, never this pane", () => {
  const { presence, changes } = client();
  presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
  expect(presence.presenceOf("s1")).toBeUndefined();
  presence.notification({ sessionId: "s1", participants: [me, { ...ana, typing: true }] });
  expect(presence.presenceOf("s1")?.viewing.map((p) => p.id)).toEqual([ana.id]);
  expect(presence.presenceOf("s1")?.typing.map((p) => p.id)).toEqual([ana.id]);
  // Another chat's presence and a switch never show here.
  presence.notification({ sessionId: "s2", participants: [] });
  expect(presence.presenceOf("s2")).toBeUndefined();
  const before = changes();
  presence.notification({ sessionId: "s1", participants: [me, { ...ana, typing: true }] });
  expect(changes()).toBe(before);
  presence.detached();
  expect(presence.presenceOf("s1")).toBeUndefined();
});

test("typing is on once, refreshed before acpmux's expiry, and off on send or empty text", () => {
  const { presence, sent, tick } = client();
  presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
  presence.typed("h");
  presence.typed("he");
  expect(sent).toEqual([{ sessionId: "s1", on: true }]);
  tick(TYPING_REFRESH_MS);
  presence.typed("hel");
  expect(sent.length).toBe(2);
  presence.typed("");
  expect(sent.at(-1)).toEqual({ sessionId: "s1", on: false });
  presence.typed("again");
  presence.stopTyping();
  expect(sent.at(-1)).toEqual({ sessionId: "s1", on: false });
  presence.stopTyping();
  expect(sent.filter((s) => !s.on).length).toBe(2);
});

test("no keystroke for the idle time turns typing off", () => {
  jest.useFakeTimers();
  try {
    const { presence, sent } = client();
    presence.attached("s1", { presence: { sessionId: "s1", participants: [] } });
    presence.typed("x");
    jest.advanceTimersByTime(TYPING_IDLE_MS - 1);
    expect(sent.at(-1)).toEqual({ sessionId: "s1", on: true });
    jest.advanceTimersByTime(1);
    expect(sent.at(-1)).toEqual({ sessionId: "s1", on: false });
  } finally {
    jest.useRealTimers();
  }
});

// A teammate's pane (through the host daemon) is not acpmux's `owner`: the attach reply names its
// own id, so it sees the owner and not itself.
test("a teammate's pane leaves out the id its attach reply names, and shows the owner", () => {
  const { presence } = client();
  presence.attached("s1", { you: { id: ana.id }, presence: { sessionId: "s1", participants: [me, ana] } });
  expect(presence.presenceOf("s1")?.viewing.map((p) => p.id)).toEqual(["owner"]);
  presence.notification({ sessionId: "s1", participants: [me, { ...ana, typing: true }] });
  expect(presence.presenceOf("s1")?.typing).toEqual([]);
  // The next chat without `you` is the pane's own again.
  presence.attached("s2", { presence: { sessionId: "s2", participants: [me, ana] } });
  expect(presence.presenceOf("s2")?.viewing.map((p) => p.id)).toEqual([ana.id]);
});

test("a notification after an attach without presence shows nobody and turns no typing on", () => {
  const { presence, sent } = client();
  presence.attached("s1", { events: [] });
  presence.notification({ sessionId: "s1", participants: [me, { ...ana, typing: true }] });
  expect(presence.presenceOf("s1")).toBeUndefined();
  presence.typed("hello");
  expect(sent).toEqual([]);
});

test("a detached pane's keystrokes reach no chat until the next attach", () => {
  const { presence, sent } = client();
  presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
  presence.typed("h");
  // A switch: the chat before hears the off at once, then nothing while the next attach is pending.
  presence.detached();
  expect(sent).toEqual([
    { sessionId: "s1", on: true },
    { sessionId: "s1", on: false },
  ]);
  presence.typed("he");
  expect(sent.length).toBe(2);
  expect(presence.presenceOf("s1")).toBeUndefined();
  // The attach fails: still nothing. It lands for s2: typing goes to s2.
  presence.typed("hel");
  expect(sent.length).toBe(2);
  presence.attached("s2", { presence: { sessionId: "s2", participants: [me] } });
  presence.typed("hell");
  expect(sent.at(-1)).toEqual({ sessionId: "s2", on: true });
  presence.detached();
});

const refused = () => Promise.reject(Object.assign(new Error("slow down"), { reason: "typing.rate_limited" }));
/// The retries on a fake clock: `elapse` runs the timers due in `ms` in small steps, letting each
/// refused send's answer (a microtask) schedule its retry before the clock moves on.
const flush = async () => {
  for (let i = 0; i < 10; i += 1) await Promise.resolve();
};
const elapse = async (ms: number) => {
  for (let at = 0; at < ms; at += 25) {
    jest.advanceTimersByTime(Math.min(25, ms - at));
    await flush();
  }
};
const faked = (run: () => Promise<void>) => async () => {
  jest.useFakeTimers();
  try {
    await run();
  } finally {
    jest.useRealTimers();
  }
};

test(
  "an off refused for the rate goes again, a bounded number of times",
  faked(async () => {
    const sent: { sessionId: string; on: boolean }[] = [];
    const presence = new PresenceClient(
      (_method, params) => {
        sent.push(params);
        return params.on ? Promise.resolve({}) : refused();
      },
      () => {},
    );
    presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
    presence.typed("h");
    presence.stopTyping();
    await elapse(STOP_RETRY_MS * (STOP_RETRIES + 1) + 200);
    expect(sent.filter((s) => !s.on).length).toBe(STOP_RETRIES + 1);
  }),
  STOP_RETRY_MS * (STOP_RETRIES + 2) + 2_000,
);

test(
  "a refused off that lands on retry stops, and typing again cancels a pending retry",
  faked(async () => {
    const sent: { sessionId: string; on: boolean }[] = [];
    let refusals = 1;
    const presence = new PresenceClient(
      (_method, params) => {
        sent.push(params);
        if (!params.on && refusals > 0) {
          refusals -= 1;
          return refused();
        }
        return Promise.resolve({});
      },
      () => {},
    );
    presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
    presence.typed("h");
    presence.stopTyping();
    await elapse(STOP_RETRY_MS + 200);
    expect(sent.filter((s) => !s.on).length).toBe(2);
    await elapse(STOP_RETRY_MS + 200);
    expect(sent.filter((s) => !s.on).length).toBe(2);
    // Refused again, then typing starts before the retry: no stale off follows the on.
    refusals = 1;
    presence.typed("again");
    presence.stopTyping();
    await flush();
    presence.typed("again and again");
    await elapse(STOP_RETRY_MS + 200);
    expect(sent.at(-1)).toEqual({ sessionId: "s1", on: true });
    presence.detached();
    await flush();
  }),
  STOP_RETRY_MS * 4 + 2_000,
);

test("a keystroke in the chat still shown while the next one attaches says nothing to the next one", () => {
  const { presence, sent } = client();
  presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
  presence.detached();
  // The switch's attach landed for s2, but the pane still shows s1 (its snapshots held).
  presence.attached("s2", { presence: { sessionId: "s2", participants: [me] } });
  presence.typed("for s1", "s1");
  expect(sent).toEqual([]);
  expect(presence.chat).toBe("s2");
  // The chat before clears its prompt (a send there, its draft emptied): no stop for s2 either.
  presence.typed("", "s1");
  expect(sent).toEqual([]);
  // s2 shows: its own composer's keystrokes go to it.
  presence.typed("for s2", "s2");
  expect(sent).toEqual([{ sessionId: "s2", on: true }]);
  // A late clear from the chat before does not stop s2's typing.
  presence.typed("", "s1");
  expect(sent).toEqual([{ sessionId: "s2", on: true }]);
});

test(
  "an off for the chat before, refused after the switch, is not sent again to it",
  faked(async () => {
    const sent: { sessionId: string; on: boolean }[] = [];
    let refuse: () => void = () => {};
    const presence = new PresenceClient(
      (_method, params) => {
        sent.push(params);
        if (params.on) return Promise.resolve({});
        // The first off's answer comes back late: after the pane shows s2.
        return params.sessionId === "s1"
          ? new Promise((_resolve, reject) => {
              refuse = () => reject(Object.assign(new Error("slow down"), { reason: "typing.rate_limited" }));
            })
          : Promise.resolve({});
      },
      () => {},
    );
    presence.attached("s1", { presence: { sessionId: "s1", participants: [me] } });
    presence.typed("h");
    presence.detached();
    presence.attached("s2", { presence: { sessionId: "s2", participants: [me] } });
    // s2's own typing starts before s1's off is refused: that refusal is not retried to s1.
    presence.typed("in s2");
    refuse();
    await elapse(STOP_RETRY_MS + 200);
    expect(sent.filter((s) => s.sessionId === "s1")).toEqual([
      { sessionId: "s1", on: true },
      { sessionId: "s1", on: false },
    ]);
    expect(sent.at(-1)).toEqual({ sessionId: "s2", on: true });
    presence.detached();
    await flush();
  }),
  STOP_RETRY_MS * 2 + 2_000,
);
