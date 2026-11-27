// A new chat's typed text goes to the host at most every 300 ms while typing, its last text always goes,
// a flush sends at once, and "" never goes before a non-empty text (the relaunch seed guard).
// Lead decision 2026-10-25 (slice c group 2 review): the old 300 ms debounce lost all text typed without a
// pause on a crash. A fake clock and timer: no real waiting.
import { describe, expect, test } from "bun:test";
import { createUnsentDraftThrottle } from "../src/agent-session/acpmux/unsentDraftThrottle";

function rig() {
  let clock = 0;
  const timers: { at: number; run: () => void; id: number }[] = [];
  let nextId = 1;
  const sent: { text: string; at: number }[] = [];
  const throttle = createUnsentDraftThrottle({
    send: (text) => sent.push({ text, at: clock }),
    intervalMs: 300,
    now: () => clock,
    setTimer: (run, ms) => {
      const id = nextId++;
      timers.push({ at: clock + ms, run, id });
      return id;
    },
    clearTimer: (id) => {
      const index = timers.findIndex((timer) => timer.id === id);
      if (index >= 0) timers.splice(index, 1);
    },
  });
  const advance = (ms: number) => {
    const end = clock + ms;
    for (;;) {
      timers.sort((a, b) => a.at - b.at);
      const next = timers[0];
      if (!next || next.at > end) break;
      timers.shift();
      clock = next.at;
      next.run();
    }
    clock = end;
  };
  return { throttle, sent, advance };
}

describe("unsent draft throttle", () => {
  test("continuous typing sends at most every 300 ms, and the final text", () => {
    const { throttle, sent, advance } = rig();
    let text = "";
    for (let key = 0; key < 40; key++) {
      text += "a";
      throttle.push(text);
      advance(50); // a key every 50 ms, no pause for 2 s
    }
    advance(1_000);
    expect(sent[0]).toEqual({ text: "a", at: 0 }); // leading edge: the first change goes at once
    for (let i = 1; i < sent.length; i++) expect(sent[i]!.at - sent[i - 1]!.at).toBeGreaterThanOrEqual(300);
    expect(sent.at(-1)!.text).toBe("a".repeat(40)); // trailing edge: the last text goes
    expect(sent.length).toBeGreaterThan(5); // it went during the typing, not only at its end
  });

  test('"" before the seed arrives sends nothing; after a sent text it does', () => {
    const { throttle, sent, advance } = rig();
    throttle.push("");
    advance(1_000);
    expect(sent).toEqual([]);
    throttle.push("compare the two retry policies"); // the seed (or the first typed text)
    advance(1_000);
    throttle.push("");
    advance(1_000);
    expect(sent.map((entry) => entry.text)).toEqual(["compare the two retry policies", ""]);
  });

  test("a flush sends the waiting text at once", () => {
    const { throttle, sent, advance } = rig();
    throttle.push("a");
    throttle.push("ab"); // waits for the interval
    expect(sent.map((entry) => entry.text)).toEqual(["a"]);
    throttle.flush(); // blur, the page hidden, or a send
    expect(sent.map((entry) => entry.text)).toEqual(["a", "ab"]);
    advance(1_000);
    expect(sent.length).toBe(2); // nothing more: the timer was stopped
  });
});
