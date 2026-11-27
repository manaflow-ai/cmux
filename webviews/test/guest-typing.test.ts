// The guest's typing signal (agent-session/guest/typingSignal.ts): on at the first keystroke, off on
// send, clear or 5 s idle, never more than two frames a second, on one-shot timers.
import { expect, test } from "bun:test";
import { TYPING_GAP_MS, TYPING_IDLE_MS, TypingSignal } from "../src/agent-session/guest/typingSignal";

function clock() {
  let now = 0;
  let next = 0;
  const timers = new Map<number, { at: number; run: () => void }>();
  return {
    timers: {
      set: (run: () => void, ms: number) => {
        timers.set(++next, { at: now + ms, run });
        return next;
      },
      clear: (id: unknown) => void timers.delete(id as number),
      now: () => now,
    },
    pending: () => timers.size,
    /** Moves time on, running each timer that comes due, in order. */
    advance(ms: number) {
      const end = now + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        timers.delete(due[0]);
        now = due[1].at;
        due[1].run();
      }
      now = end;
    },
  };
}

function signal(live = () => true) {
  const time = clock();
  const sent: boolean[] = [];
  const typing = new TypingSignal((on) => live() && (sent.push(on), true), time.timers);
  return { time, sent, typing };
}

test("on at the first keystroke only, off after 5 s without one", () => {
  const { time, sent, typing } = signal();
  typing.input("h");
  typing.input("he");
  time.advance(1_000);
  typing.input("hel");
  expect(sent).toEqual([true]);
  time.advance(TYPING_IDLE_MS - 1);
  expect(sent).toEqual([true]);
  time.advance(1);
  expect(sent).toEqual([true, false]);
  expect(time.pending()).toBe(0);
});

test("off on send or clear; a draft of spaces is no typing", () => {
  const { time, sent, typing } = signal();
  typing.input("hi");
  time.advance(600);
  typing.stop();
  expect(sent).toEqual([true, false]);
  time.advance(600);
  typing.input("   ");
  expect(sent).toEqual([true, false]);
  typing.input("x");
  time.advance(600);
  typing.input("");
  expect(sent).toEqual([true, false, true, false]);
});

test("at most two frames a second: a change inside the gap goes when it ends, if it still differs", () => {
  const { time, sent, typing } = signal();
  typing.input("a");
  typing.stop();
  typing.input("b");
  expect(sent).toEqual([true]);
  time.advance(TYPING_GAP_MS);
  // Off and on again inside the gap: the room already hears on, so nothing goes.
  expect(sent).toEqual([true]);
  typing.stop();
  time.advance(100);
  typing.input("c");
  typing.stop();
  expect(sent).toEqual([true, false]);
  time.advance(TYPING_GAP_MS);
  expect(sent).toEqual([true, false]);
});

test("with no connection nothing is sent; a reconnect sends the current state", () => {
  let live = false;
  const { time, sent, typing } = signal(() => live);
  typing.input("hi");
  expect(sent).toEqual([]);
  live = true;
  typing.reset();
  expect(sent).toEqual([true]);
  typing.dispose();
  time.advance(TYPING_IDLE_MS);
  expect(sent).toEqual([true]);
});
