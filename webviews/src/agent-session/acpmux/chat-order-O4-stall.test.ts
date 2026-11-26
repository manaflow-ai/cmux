// Ordering map O4 (design/chat-animation-ordering-map.md): a reply streaming with a gap over 600 ms,
// the late delta lands on a stalled reveal and its backlog drains. Leo, 2026-11-21: "some animations
// i think are still a bit... off. like, you finish some sort of tool call, things happen, things fold,
// stuff comes in at different times"; "sometimes animations sprint for no reason".
// The late delta drains like the finish at a tool boundary (O3, streamReveal.test.ts): at no more
// than twice the rate the stream flowed at, within the catch-up bound, and a second stall gets its own
// deadline.
import { expect, test } from "bun:test";
import { StreamReveal } from "./streamReveal";

/// Streams 16 chars per 50 ms for 2 s, stalls `stallMs` (frames keep running, the stream does not
/// end), then one delta of `late` characters lands. Returns the fastest chars/s drawn in any frame
/// from the delta on, how long the backlog took to show, and the arrival rate.
function stalled(stallMs: number, late: number) {
  const reveal = new StreamReveal();
  const frame = 1000 / 120;
  let text = "";
  let now = 0;
  let nextDelta = 0;
  for (; now < 2000; now += frame) {
    while (nextDelta <= now) {
      text += "x".repeat(16);
      nextDelta += 50;
    }
    reveal.advance(text, now, false);
  }
  // The stream goes quiet; the reveal keeps its frames.
  const quietUntil = now + stallMs;
  for (; now < quietUntil; now += frame) reveal.advance(text, now, false);
  text += "x".repeat(late);
  const landed = now;
  let shown = reveal.advance(text, now, false);
  let fastest = 0;
  while (shown < text.length && now < landed + 3000) {
    now += frame;
    const next = reveal.advance(text, now, false);
    fastest = Math.max(fastest, ((next - shown) / frame) * 1000);
    shown = next;
  }
  return { fastest, took: now - landed, rate: (16 / 50) * 1000 };
}

test("O4: a late delta after a stall drains within the catch-up bound (900 ms), inside the 4,000 chars/s ceiling", () => {
  for (const [stallMs, late] of [
    [800, 200],
    [1500, 400],
  ] as const) {
    const { fastest, took, rate } = stalled(stallMs, late);
    expect(took).toBeLessThanOrEqual(StreamReveal.maxBacklogMs + 20);
    // Frame rounding and the whole-word cut: two frames of slack, as the finish test.
    expect(fastest).toBeLessThanOrEqual(Math.max(rate * StreamReveal.finishSpeedup * 1.25, 1000 * 4));
  }
});

test("O4: a second stall drains again on its own deadline, not the first one's", () => {
  const reveal = new StreamReveal();
  const frame = 1000 / 120;
  let text = "";
  let now = 0;
  const run = (ms: number) => {
    for (const end = now + ms; now < end; now += frame) reveal.advance(text, now, false);
  };
  for (let round = 0; round < 3; round += 1) {
    text += "x".repeat(300);
    run(StreamReveal.stallMs + StreamReveal.maxLagMs + 100);
    // Each round's backlog is shown by the end of its own stall window.
    expect(reveal.advance(text, now, false)).toBe(text.length);
  }
});

// Was red: the late delta registered its arrival in the same frame, so the frame was no longer
// `stalled` and the backlog was drawn by the lag correction (rate + backlog / correctMs 250 ms):
// 1,080 chars/s for 200 characters and 1,800 chars/s for 400, 3.4x and 5.6x the 320 chars/s the
// reader followed. Now a delta after a stall drains like a finish, at twice the flow rate at most.
test("O4: the late delta's backlog draws at no more than twice the arrival rate", () => {
  for (const [stallMs, late] of [
    [800, 200],
    [1500, 400],
  ] as const) {
    const { fastest, rate } = stalled(stallMs, late);
    expect(fastest).toBeLessThanOrEqual(rate * StreamReveal.finishSpeedup * 1.25);
  }
});
