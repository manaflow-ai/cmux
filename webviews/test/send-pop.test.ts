// A sent prompt pops in where it sits (conversation.css SEND-POP; Leo 2026-11-22: "it does a little pop
// and settle"): Claude's own user-message entrance, on transform alone, on the scale's send-pop step.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import {
  MOTION_EASE_SEND_POP,
  MOTION_SEND_MS,
  MOTION_SEND_POP_FROM,
  MOTION_SEND_POP_MS,
} from "../src/motion/scale.generated";

const css = fs.readFileSync(
  path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
  "utf8",
);
const keyframes = (name: string) => {
  const start = css.indexOf(`@keyframes ${name} {`);
  expect(start).toBeGreaterThanOrEqual(0);
  return css.slice(start, css.indexOf("\n}\n", start));
};
const at = (x1: number, y1: number, x2: number, y2: number, x: number) => {
  let lo = 0;
  let hi = 1;
  for (let step = 0; step < 60; step++) {
    const t = (lo + hi) / 2;
    const bx = 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t * t * x2 + t ** 3;
    if (bx < x) lo = t;
    else hi = t;
  }
  const t = (lo + hi) / 2;
  return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t * t * y2 + t ** 3;
};

describe("sent prompt pop", () => {
  test("is Claude's cds-um-enter: 450 ms, cubic-bezier(.34, 1.3, .64, 1), from scale .92 and 6px low", () => {
    expect(MOTION_SEND_POP_MS).toBe(450);
    expect(MOTION_EASE_SEND_POP).toBe("cubic-bezier(0.34, 1.3, 0.64, 1)");
    expect(MOTION_SEND_POP_FROM).toEqual({ scale: 0.92, rise: 6 });
    const from = keyframes("cv-send-pop");
    expect(from).toContain(`scale(${MOTION_SEND_POP_FROM.scale}) translateY(${MOTION_SEND_POP_FROM.rise}px)`);
  });

  test("passes its size and settles back: a pop, not a plain ease", () => {
    const [x1, y1, x2, y2] = MOTION_EASE_SEND_POP.match(/[\d.]+/g)!.map(Number) as [number, number, number, number];
    const samples = Array.from({ length: 46 }, (_, index) => at(x1, y1, x2, y2, index / 45));
    const peak = Math.max(...samples);
    const peakMs = (samples.indexOf(peak) / 45) * MOTION_SEND_POP_MS;
    expect(peak).toBeGreaterThan(1.02);
    expect(peak).toBeLessThan(1.04);
    expect(peakMs).toBeGreaterThan(250);
    expect(peakMs).toBeLessThan(350);
    expect(samples.at(-1)).toBeCloseTo(1, 3);
  });

  test("moves transform alone (compositor), on the presentation wrapper of the sent prompt only", () => {
    for (const name of ["cv-send-pop", "cv-send-pop-spring"]) {
      const frames = keyframes(name);
      expect(frames).not.toMatch(/\b(width|height|top|left|margin|padding|clip-path|filter)\s*:/);
    }
    const rule = css.match(
      /\.acpmux-user\.acpmux-row--message-enter:not\(\.acpmux-row--line, \[data-send-morphed\]\) > \.acpmux-row__message-presentation \{([^}]*)\}/,
    );
    expect(rule?.[1]).toContain("cv-send-pop var(--agent-motion-send-pop");
    expect(rule?.[1]).toContain("var(--cmux-ease-send-pop");
    expect(rule?.[1]).toContain("transform-origin: right center");
  });

  test("the room, the thread and the thinking row still land at once", () => {
    expect(MOTION_SEND_MS).toBe(0);
  });
});
