// The read model's client half (attention.ts; design/transcript-overlays.md "What counts as seen"):
// the person attends the chat only while it is on screen, focused, and they gave input within the
// idle window. Pinned at the bottom while idle is not attending; acpmux keeps those turns unread
// (cmux-tui hub/seen_tests.rs drives the daemon half).
import { expect, test } from "bun:test";
import { ATTENTION_IDLE_MS, Attention, attending, type AttentionEnv } from "./attention";

/// A page with a hand-driven clock, focus and visibility.
function fakePage(start = { shown: true, focused: true }) {
  let now = 1_000_000;
  let shown = start.shown;
  let focused = start.focused;
  const timers = new Map<number, { at: number; run: () => void }>();
  let next = 1;
  let input = () => {};
  let focusChange = () => {};
  const env: AttentionEnv = {
    now: () => now,
    shown: () => shown,
    focused: () => focused,
    setTimer(run, ms) {
      const id = next++;
      timers.set(id, { at: now + ms, run });
      return id;
    },
    clearTimer: (id) => void timers.delete(id as number),
    listen(onInput, onFocusChange) {
      input = onInput;
      focusChange = onFocusChange;
      return () => {
        input = () => {};
        focusChange = () => {};
      };
    },
  };
  const advance = (ms: number) => {
    const until = now + ms;
    for (;;) {
      const due = [...timers.entries()].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      now = due[1].at;
      due[1].run();
    }
    now = until;
  };
  return {
    env,
    advance,
    input: () => input(),
    setFocused(next: boolean) {
      focused = next;
      focusChange();
    },
    setShown(next: boolean) {
      shown = next;
      focusChange();
    },
    pendingTimers: () => timers.size,
  };
}

test("attending needs the page on screen, focus, and input inside the idle window", () => {
  const now = 10 * ATTENTION_IDLE_MS;
  const base = { shown: true, focused: true, lastInputAt: now - 1, now };
  expect(attending(base)).toBe(true);
  expect(attending({ ...base, shown: false })).toBe(false);
  expect(attending({ ...base, focused: false })).toBe(false);
  expect(attending({ ...base, lastInputAt: undefined })).toBe(false);
  expect(attending({ ...base, lastInputAt: now - ATTENTION_IDLE_MS })).toBe(false);
  expect(attending({ ...base, lastInputAt: now - ATTENTION_IDLE_MS + 1 })).toBe(true);
});

test("idle at the bottom: with no input for the window, the person stops attending", () => {
  const page = fakePage();
  const flips: boolean[] = [];
  const attention = new Attention(page.env, (next) => flips.push(next));
  // Opening on screen and focused is the person's doing.
  expect(attention.now()).toBe(true);
  // Rows stream in and the view follows them: no input from the person.
  page.advance(ATTENTION_IDLE_MS - 1);
  expect(attention.now()).toBe(true);
  expect(flips).toEqual([]);
  page.advance(1);
  expect(attention.now()).toBe(false);
  expect(flips).toEqual([false]);
  // Nothing keeps ticking while idle.
  expect(page.pendingTimers()).toBe(0);
  attention.dispose();
});

test("active at the bottom: input keeps the person attending, without a timer per input", () => {
  const page = fakePage();
  const flips: boolean[] = [];
  const attention = new Attention(page.env, (next) => flips.push(next));
  for (let i = 0; i < 10; i++) {
    page.advance(ATTENTION_IDLE_MS / 2);
    page.input();
    expect(page.pendingTimers()).toBe(1);
  }
  expect(attention.now()).toBe(true);
  expect(flips).toEqual([]);
  attention.dispose();
});

test("coming back is one flip, and its input notes where the person is", () => {
  const page = fakePage();
  const flips: boolean[] = [];
  let noted = 0;
  const attention = new Attention(page.env, (next) => flips.push(next), () => (noted += 1));
  page.advance(ATTENTION_IDLE_MS);
  expect(flips).toEqual([false]);
  const before = noted;
  page.input();
  expect(flips).toEqual([false, true]);
  expect(noted).toBe(before + 1);
  // Pointer moves within a second note once.
  page.advance(10);
  page.input();
  page.advance(10);
  page.input();
  expect(noted).toBe(before + 1);
  attention.dispose();
});

test("an inactive window or a hidden page is not attending, however recent the input", () => {
  const page = fakePage();
  const flips: boolean[] = [];
  const attention = new Attention(page.env, (next) => flips.push(next));
  page.setFocused(false);
  expect(attention.now()).toBe(false);
  page.input();
  expect(attention.now()).toBe(false);
  page.setFocused(true);
  expect(attention.now()).toBe(true);
  page.setShown(false);
  expect(attention.now()).toBe(false);
  expect(flips).toEqual([false, true, false]);
  attention.dispose();
});

test("a page restored without focus waits for the person", () => {
  const page = fakePage({ shown: true, focused: false });
  const attention = new Attention(page.env, () => {});
  expect(attention.now()).toBe(false);
  page.setFocused(true);
  expect(attention.now()).toBe(true);
  attention.dispose();
});
