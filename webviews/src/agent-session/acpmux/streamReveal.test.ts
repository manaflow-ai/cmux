// A reply's last lines when its stream ends (a tool call starts): the backlog drains no faster than
// twice the arrival rate, or in the 180 ms finish when that is slower, and always within the longest
// lag (350 ms). Leo, 2026-11-21: "sometimes animations sprint for no reason"
// (design/chat-animation-ordering-map.md O3, O4).
import { expect, test } from "bun:test";
import { StreamReveal } from "./streamReveal";

/// Streams `chars` characters per `gapMs` for `ms`, then ends; returns the most characters drawn per
/// second over any frame after the end, the time the finish took, and the arrival rate.
function finish(chars: number, gapMs: number, ms: number, lastBurst = 0) {
  const reveal = new StreamReveal();
  let text = "";
  let now = 0;
  const frame = 1000 / 120;
  let nextDelta = 0;
  for (; now < ms; now += frame) {
    while (nextDelta <= now) {
      text += "x".repeat(chars);
      nextDelta += gapMs;
    }
    reveal.advance(text, now, false);
  }
  const rate = (chars / gapMs) * 1000;
  // A last delta far larger than the rest (Codex flushes a run of tokens as its turn moves on).
  text += "x".repeat(lastBurst);
  reveal.advance(text, now, false);
  let shown = reveal.advance(text, now, true);
  const endAt = now;
  let fastest = 0;
  while (shown < text.length && now < endAt + 2000) {
    now += frame;
    const next = reveal.advance(text, now, true);
    fastest = Math.max(fastest, ((next - shown) / frame) * 1000);
    shown = next;
  }
  return { fastest, took: now - endAt, rate };
}

test("a steady stream's end finishes at no more than twice its arrival rate, inside the longest lag", () => {
  for (const [chars, gap] of [
    [16, 50],
    [40, 30],
    [4, 100],
  ] as const) {
    const { fastest, took, rate } = finish(chars, gap, 3000);
    expect(took).toBeLessThanOrEqual(StreamReveal.maxLagMs + 20);
    // Two frames of slack for the whole-word cut and frame rounding.
    expect(fastest).toBeLessThanOrEqual(Math.max(rate * StreamReveal.finishSpeedup * 1.25, 1000 * 4));
  }
});

test("a big last burst before a tool call drains over the longest lag, not in one standard-step sprint", () => {
  // 320 chars/s, then 300 characters at once and the stream ends: the old 180 ms finish drew them at
  // about 1,700 chars/s, five times the rate the reader was following.
  const { fastest, took } = finish(16, 50, 3000, 300);
  expect(took).toBeGreaterThanOrEqual(StreamReveal.maxLagMs - 20);
  expect(took).toBeLessThanOrEqual(StreamReveal.maxLagMs + 20);
  expect(fastest).toBeLessThan(1_100);
});
