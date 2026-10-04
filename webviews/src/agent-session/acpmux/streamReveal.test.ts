import { describe, expect, test } from "bun:test";
import { StreamReveal } from "./streamReveal";

const FRAME = 1000 / 120;

/// Runs frames at 120 Hz from `start` until `until` returns true or `limit` frames pass; returns
/// the visible lengths per frame.
function run(reveal: StreamReveal, target: () => string, done: () => boolean, frames: number, start = 0) {
  const shown: number[] = [];
  for (let frame = 0; frame < frames; frame += 1) shown.push(reveal.advance(target(), start + frame * FRAME, done()));
  return shown;
}

describe("StreamReveal", () => {
  test("text that is already there when the row mounts shows at once", () => {
    const reveal = new StreamReveal({ initial: "Hello there" });
    expect(reveal.advance("Hello there", 0, false)).toBe(11);
  });

  test("new text appears over frames, never going back, and catches up within the catch-up time", () => {
    const reveal = new StreamReveal();
    const text = "The quick brown fox jumps over the lazy dog. ".repeat(4);
    const shown = run(reveal, () => text, () => false, 60);
    expect(shown[0]).toBeLessThan(text.length);
    for (let index = 1; index < shown.length; index += 1) expect(shown[index]).toBeGreaterThanOrEqual(shown[index - 1]);
    const caughtUp = shown.findIndex((length) => length === text.length);
    expect(caughtUp).toBeGreaterThan(2);
    expect(caughtUp * FRAME).toBeLessThanOrEqual(StreamReveal.catchUpMs + 4 * FRAME);
  });

  test("a larger backlog reveals faster, so the delay stays about the same", () => {
    const framesToCatchUp = (length: number) => {
      const reveal = new StreamReveal();
      const text = "word ".repeat(length / 5);
      return run(reveal, () => text, () => false, 200).findIndex((shown) => shown === text.length);
    };
    const small = framesToCatchUp(100);
    const large = framesToCatchUp(2000);
    expect(large).toBeLessThanOrEqual(small + 6);
  });

  test("a slow stream still reveals at the minimum rate, not one character a minute", () => {
    const reveal = new StreamReveal();
    const shown = run(reveal, () => "abcdefghij", () => false, 30);
    expect(shown.at(-1)).toBe(10);
  });

  test("a frame ends on a word boundary when one is near", () => {
    const reveal = new StreamReveal();
    const text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu";
    for (const length of run(reveal, () => text, () => false, 40))
      if (length > 0 && length < text.length) expect(text[length] === " " || text[length - 1] === " ").toBe(true);
  });

  test("an ended stream shows the rest quickly", () => {
    const reveal = new StreamReveal();
    const text = "x".repeat(5000);
    const shown = run(reveal, () => text, () => true, 20);
    expect(shown.findIndex((length) => length === text.length) * FRAME).toBeLessThanOrEqual(StreamReveal.finishMs + 2 * FRAME);
  });

  test("with Reduce Motion everything shows at once", () => {
    const reveal = new StreamReveal({ reduceMotion: true });
    expect(reveal.advance("all of it", 0, false)).toBe(9);
  });

  test("a long pause between frames does not dump the whole backlog in one frame", () => {
    const reveal = new StreamReveal();
    const text = "word ".repeat(400);
    reveal.advance(text, 0, false);
    const after = reveal.advance(text, 5_000, false);
    expect(after).toBeLessThan(text.length);
  });

  test("a text that got shorter (a superseded message) clamps instead of overrunning", () => {
    const reveal = new StreamReveal({ initial: "a long first draft" });
    expect(reveal.advance("short", 0, false)).toBe(5);
  });

  test("never splits a surrogate pair", () => {
    const reveal = new StreamReveal();
    const text = "😀".repeat(200);
    for (const length of run(reveal, () => text, () => false, 30)) {
      const code = text.charCodeAt(length - 1);
      if (length > 0 && length < text.length) expect(code >= 0xd800 && code <= 0xdbff).toBe(false);
    }
  });

  test("settled says when the reveal has caught up", () => {
    const reveal = new StreamReveal();
    reveal.advance("ab", 0, false);
    expect(reveal.settled).toBe(false);
    run(reveal, () => "ab", () => false, 30, FRAME);
    expect(reveal.settled).toBe(true);
  });
});
