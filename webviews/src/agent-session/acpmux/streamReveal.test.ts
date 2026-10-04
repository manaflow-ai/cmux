import { describe, expect, test } from "bun:test";
import { StreamReveal } from "./streamReveal";

const FRAME = 1000 / 120;

/// A recorded cadence: `chars` more characters arrive at each `at` (ms). Frames run at 120 Hz
/// until `until`; returns the visible length per frame and the text.
function play(arrivals: { at: number; chars: number }[], until: number, done = Number.POSITIVE_INFINITY) {
  const reveal = new StreamReveal();
  let text = "";
  let next = 0;
  const shown: { at: number; length: number; received: number }[] = [];
  for (let now = 0; now <= until; now += FRAME) {
    while (next < arrivals.length && arrivals[next]!.at <= now) text += "w".repeat(arrivals[next++]!.chars);
    shown.push({ at: now, length: reveal.advance(text, now, now >= done), received: text.length });
  }
  return { shown, text };
}

/// Claude: ~16 characters every 50 ms.
const drip = Array.from({ length: 100 }, (_, index) => ({ at: index * 50, chars: 16 }));
/// Codex: bursts of 8 tokens 4 ms apart, then a 300 ms pause.
const bursts = Array.from({ length: 30 }, (_, burst) =>
  Array.from({ length: 8 }, (_, token) => ({ at: burst * 330 + token * 4, chars: 5 })),
).flat();

describe("StreamReveal", () => {
  test("text that is already there when the row mounts shows at once", () => {
    const reveal = new StreamReveal({ initial: "Hello there" });
    expect(reveal.advance("Hello there", 0, false)).toBe(11);
  });

  test("a steady drip flows on most frames, a few characters at a time, never going back", () => {
    const { shown } = play(drip, 5_000);
    const steps = shown.slice(1).map((frame, index) => frame.length - shown[index]!.length);
    expect(steps.every((step) => step >= 0)).toBe(true);
    const moving = steps.filter((step) => step > 0);
    expect(moving.length / steps.length).toBeGreaterThan(0.7);
    expect([...moving].sort((a, b) => a - b)[Math.floor(moving.length / 2)]!).toBeLessThanOrEqual(5);
  });

  test("a steady drip trails by about its usual gap, not more", () => {
    const { shown } = play(drip, 5_000);
    // Mid-stream: the characters not yet shown are at most ~350 ms of arrivals (320 chars/s).
    const late = shown.filter((frame) => frame.at > 2_000 && frame.at < 4_500);
    for (const frame of late) expect(frame.received - frame.length).toBeLessThanOrEqual(120);
  });

  test("bursts with pauses keep flowing through the pauses instead of stopping and jumping", () => {
    const { shown } = play(bursts, 9_000);
    const steps = shown.slice(1).map((frame, index) => frame.length - shown[index]!.length);
    const mid = steps.slice(120, 960);
    expect(mid.filter((step) => step > 0).length / mid.length).toBeGreaterThan(0.6);
    expect(Math.max(...mid)).toBeLessThanOrEqual(6);
  });

  test("an ended stream shows the rest within about 180 ms", () => {
    const { shown, text } = play([{ at: 0, chars: 3_000 }], 400, 0);
    const done = shown.findIndex((frame) => frame.length === text.length);
    expect(done * FRAME).toBeLessThanOrEqual(StreamReveal.finishMs + 2 * FRAME);
  });

  test("a stream that stops arriving drains instead of waiting for the end", () => {
    const { shown, text } = play(
      [
        { at: 0, chars: 40 },
        { at: 50, chars: 40 },
        { at: 100, chars: 40 },
      ],
      1_200,
    );
    expect(shown.at(-1)!.length).toBe(text.length);
  });

  test("a huge backlog catches up quickly", () => {
    const { shown } = play(
      [{ at: 0, chars: 20 }, { at: 50, chars: 20 }, { at: 100, chars: 5_000 }, ...drip.slice(3)],
      800,
    );
    const at = shown.find((frame) => frame.at >= 100 + StreamReveal.catchUpMs + 3 * FRAME)!;
    // Most of the 5,000-character burst shows within the catch-up time; the rest flows at the new rate.
    expect(at.received - at.length).toBeLessThan(1_250);
  });

  test("with Reduce Motion everything shows at once", () => {
    const reveal = new StreamReveal({ reduceMotion: true });
    expect(reveal.advance("all of it", 0, false)).toBe(9);
  });

  test("flush shows everything (a hidden page, a session switch)", () => {
    const reveal = new StreamReveal();
    reveal.advance("x".repeat(500), 0, false);
    reveal.flush();
    expect(reveal.advance("x".repeat(500), FRAME, false)).toBe(500);
  });

  test("a long pause between frames does not dump the whole backlog in one frame", () => {
    const reveal = new StreamReveal();
    reveal.advance("w", 0, false);
    reveal.advance("w".repeat(30), 50, false);
    reveal.advance("w".repeat(60), 100, false);
    const text = "w".repeat(2_000);
    reveal.advance(text, 110, false);
    expect(reveal.advance(text, 5_000, false)).toBeLessThan(text.length);
  });

  test("a text that got shorter (a superseded message) clamps instead of overrunning", () => {
    const reveal = new StreamReveal({ initial: "a long first draft" });
    expect(reveal.advance("short", 0, false)).toBe(5);
  });

  test("never splits a surrogate pair", () => {
    const reveal = new StreamReveal();
    const text = "😀".repeat(200);
    for (let frame = 0; frame < 60; frame += 1) {
      const length = reveal.advance(text, frame * FRAME, false);
      const code = text.charCodeAt(length - 1);
      if (length > 0 && length < text.length) expect(code >= 0xd800 && code <= 0xdbff).toBe(false);
    }
  });

  test("settled says when the reveal has caught up", () => {
    const reveal = new StreamReveal();
    reveal.advance("ab", 0, true);
    expect(reveal.settled).toBe(false);
    for (let frame = 1; frame < 40; frame += 1) reveal.advance("ab", frame * FRAME, true);
    expect(reveal.settled).toBe(true);
  });
});
