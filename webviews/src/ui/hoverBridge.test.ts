import { describe, expect, test } from "bun:test";
import { HoverBridge, HOVER_INTENT, type HoverClock, type Point } from "./hoverIntent";

class FakeClock implements HoverClock {
  now = 0;
  private next = 1;
  private timers: Array<{ at: number; id: number; run: () => void }> = [];

  set = (run: () => void, ms: number) => {
    const id = this.next++;
    this.timers.push({ at: this.now + ms, id, run });
    return id;
  };

  clear = (id: unknown) => {
    this.timers = this.timers.filter((timer) => timer.id !== id);
  };

  advance(ms: number) {
    const end = this.now + ms;
    for (;;) {
      const next = this.timers.filter((timer) => timer.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!next) break;
      this.timers = this.timers.filter((timer) => timer !== next);
      this.now = next.at;
      next.run();
    }
    this.now = end;
  }
}

const trigger = { left: 20, top: 20, right: 120, bottom: 44 };
const card = { left: 132, top: 12, right: 360, bottom: 112 };
const point = (x: number, y: number): Point => ({ x, y });

describe("hover trigger/card bridge", () => {
  test("keeps a card open across the gap and closes after leaving the safe union", () => {
    const clock = new FakeClock();
    let opened = 0;
    let closed = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: HOVER_INTENT.cardDwell,
      grace: HOVER_INTENT.cardGrace,
      open: () => (opened += 1),
      close: () => (closed += 1),
    });

    bridge.enter("trigger", trigger, point(60, 30));
    clock.advance(HOVER_INTENT.cardDwell);
    expect(opened).toBe(1);

    bridge.leave("trigger", trigger, point(124, 34));
    bridge.move(point(128, 28));
    clock.advance(HOVER_INTENT.cardGrace + 1);
    expect(closed).toBe(0);

    bridge.enter("card", card, point(132, 28));
    bridge.leave("card", card, point(500, 300));
    clock.advance(HOVER_INTENT.cardGrace - 1);
    expect(closed).toBe(0);
    clock.advance(1);
    expect(closed).toBe(1);
  });

  test("a brief exit and re-entry cancels the single close timer", () => {
    const clock = new FakeClock();
    let opened = 0;
    let closed = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: 0,
      grace: HOVER_INTENT.cardGrace,
      open: () => (opened += 1),
      close: () => (closed += 1),
    });

    bridge.enter("trigger", trigger, point(60, 30), true);
    bridge.leave("trigger", trigger, point(500, 300));
    clock.advance(HOVER_INTENT.cardGrace - 1);
    bridge.enter("trigger", trigger, point(60, 30));
    clock.advance(1);
    expect(opened).toBe(1);
    expect(closed).toBe(0);
  });

  test("a menu hold suppresses the close timer until the menu releases", () => {
    const clock = new FakeClock();
    let closed = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: 0,
      grace: HOVER_INTENT.cardGrace,
      open: () => {},
      close: () => (closed += 1),
    });

    bridge.enter("trigger", trigger, point(60, 30), true);
    bridge.hold();
    bridge.leave("trigger", trigger, point(500, 300));
    clock.advance(HOVER_INTENT.cardGrace + 1);
    expect(closed).toBe(0);
    bridge.release();
    clock.advance(HOVER_INTENT.cardGrace);
    expect(closed).toBe(1);
  });

  test("leaving near the trigger before dwell cancels without opening", () => {
    const clock = new FakeClock();
    let opened = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: HOVER_INTENT.cardDwell,
      grace: HOVER_INTENT.cardGrace,
      open: () => (opened += 1),
      close: () => {},
    });

    bridge.enter("trigger", trigger, point(60, 30));
    bridge.leave("trigger", trigger, point(trigger.right + 4, trigger.bottom / 2));
    clock.advance(HOVER_INTENT.cardDwell + 1);
    expect(opened).toBe(0);
  });

  test("a later hover clears the old card bridge after the first card closes", () => {
    const clock = new FakeClock();
    let opened = 0;
    let closed = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: HOVER_INTENT.cardDwell,
      grace: HOVER_INTENT.cardGrace,
      open: () => (opened += 1),
      close: () => (closed += 1),
    });

    bridge.enter("trigger", trigger, point(60, 30));
    clock.advance(HOVER_INTENT.cardDwell);
    bridge.enter("card", card, point(150, 30));
    bridge.leave("trigger", trigger, point(150, 30));
    bridge.leave("card", card, point(500, 300));
    clock.advance(HOVER_INTENT.cardGrace);
    expect(closed).toBe(1);

    bridge.update({ card: undefined });
    bridge.enter("trigger", trigger, point(60, 30));
    bridge.leave("trigger", trigger, point(trigger.right + 4, trigger.bottom / 2));
    clock.advance(HOVER_INTENT.cardDwell + 1);
    expect(opened).toBe(1);
  });

  test("pointer motion within the trigger does not cancel dwell", () => {
    const clock = new FakeClock();
    let opened = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: HOVER_INTENT.cardDwell,
      grace: HOVER_INTENT.cardGrace,
      open: () => (opened += 1),
      close: () => {},
    });

    bridge.enter("trigger", trigger, point(60, 30));
    bridge.move(point(70, 31));
    clock.advance(HOVER_INTENT.cardDwell);
    expect(opened).toBe(1);
  });

  test("zero-sized JSDOM geometry does not keep a pinned card open", () => {
    const clock = new FakeClock();
    let closed = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: 0,
      grace: HOVER_INTENT.cardGrace,
      open: () => {},
      close: () => (closed += 1),
    });
    const zero = { left: 0, top: 0, right: 0, bottom: 0 };

    // JSDOM's unstyled getBoundingClientRect() is all zeroes. This is the same
    // pointerout sequence ContextCard uses when its pinned card is pressed out.
    bridge.enter("trigger", zero, point(0, 0), true);
    bridge.enter("card", zero, point(0, 0), true);
    bridge.leave("trigger", zero, point(0, 0));
    bridge.leave("card", zero, point(0, 0));
    clock.advance(HOVER_INTENT.cardGrace);

    expect(closed).toBe(1);
  });

  test("entering a portal card while dwell is pending keeps a live dwell timer", () => {
    const clock = new FakeClock();
    let opened = 0;
    const bridge = new HoverBridge({
      clock,
      dwell: HOVER_INTENT.cardDwell,
      grace: HOVER_INTENT.cardGrace,
      open: () => (opened += 1),
      close: () => {},
    });

    bridge.enter("trigger", trigger, point(60, 30));
    bridge.update({ card });
    bridge.leave("trigger", trigger, point(124, 34));
    bridge.enter("card", card, point(132, 28));
    clock.advance(HOVER_INTENT.cardDwell);

    expect(opened).toBe(1);
  });
});
