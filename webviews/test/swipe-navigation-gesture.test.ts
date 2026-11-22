// Two-finger Back / Forward over an app page (swipeNavigation/gesture.ts): the pure decision fed the
// host's phase-aware trackpad events (`cmux.page.swipe`). The fixtures are NSEvent streams in the
// shape a Magic Trackpad sends at 120 Hz: a touch (`mayBegin`), `began`, `changed`..., `ended` with
// no delta, then the momentum train (`momentumPhase` began/changed/ended), with the small cross-axis
// jitter real fingers add. Natural scrolling on unless the stream says otherwise.
import { describe, expect, test } from "bun:test";
import streams from "./fixtures/trackpad-swipe-streams.json";
import {
  SWIPE,
  SwipeGesture,
  rubberBand,
  type SwipeContext,
  type SwipeEvent,
  type SwipeStep,
} from "../src/swipeNavigation/gesture";

type Row = [string, number, number, number, number];

function events(name: keyof typeof streams, extra: Partial<SwipeEvent> = {}): SwipeEvent[] {
  return (streams[name] as unknown as Row[]).map(([phase, momentum, dx, dy, time]) => ({
    phase: phase as SwipeEvent["phase"],
    momentum: momentum === 1,
    dx,
    dy,
    time,
    ...(phase === "began" && momentum === 0 ? { back: true, forward: true } : {}),
    ...extra,
  }));
}

function context(over: Partial<SwipeContext> = {}): SwipeContext {
  return { width: 800, keeps: () => false, ...over };
}

function run(gesture: SwipeGesture, list: SwipeEvent[], ctx = context()): SwipeStep[] {
  return list.map((event) => gesture.feed(event, ctx));
}

const kinds = (steps: SwipeStep[]) => steps.map((step) => step.kind).filter((kind) => kind !== "none");

describe("swipe gesture", () => {
  test("a back swipe past the threshold follows the fingers and commits on lift", () => {
    const gesture = new SwipeGesture();
    const steps = run(gesture, events("backCommit"));
    const tracks = steps.filter((step) => step.kind === "track");
    expect(tracks.length).toBeGreaterThan(5);
    // Progress follows the fingers: it only grows while they keep moving right.
    const progress = tracks.map((step) => (step.kind === "track" ? step.progress : 0));
    expect(progress).toEqual([...progress].sort((a, b) => a - b));
    expect(tracks.at(-1)).toMatchObject({ direction: "back", available: true, armed: true });
    const commits = steps.filter((step) => step.kind === "commit");
    expect(commits).toEqual([{ kind: "commit", direction: "back" }]);
    // The momentum train after the lift starts nothing.
    const lift = steps.findIndex((step) => step.kind === "commit");
    expect(kinds(steps.slice(lift + 1))).toEqual([]);
    expect(gesture.mode).toBe("idle");
  });

  test("fingers moving left go forward", () => {
    const steps = run(new SwipeGesture(), events("forwardCommit"));
    expect(steps.find((step) => step.kind === "commit")).toEqual({ kind: "commit", direction: "forward" });
  });

  test("with natural scrolling off the deltas flip and the same finger motion is still Back", () => {
    const steps = run(new SwipeGesture(), events("backCommitNaturalOff", { inverted: false }));
    expect(steps.find((step) => step.kind === "commit")).toEqual({ kind: "commit", direction: "back" });
  });

  test("a short swipe that stops before the lift springs back", () => {
    const steps = run(new SwipeGesture(), events("backShortSlow"));
    expect(kinds(steps).at(-1)).toBe("cancel");
    expect(steps.some((step) => step.kind === "commit")).toBe(false);
    const cancel = steps.find((step) => step.kind === "cancel");
    expect(cancel?.kind === "cancel" && cancel.progress).toBeGreaterThan(0);
  });

  test("a fast flick commits below the distance threshold", () => {
    const steps = run(new SwipeGesture(), events("backFlick"));
    const last = steps.filter((step) => step.kind === "track").at(-1);
    expect(last?.kind === "track" && last.progress).toBeLessThan(SWIPE.commit);
    expect(steps.find((step) => step.kind === "commit")).toEqual({ kind: "commit", direction: "back" });
  });

  test("reversing past the start cancels, and the rest of the gesture stays with the page", () => {
    const gesture = new SwipeGesture();
    const steps = run(gesture, events("reversal"));
    expect(kinds(steps)).toEqual([...kinds(steps).filter((kind) => kind === "track"), "cancel"]);
    expect(steps.some((step) => step.kind === "commit")).toBe(false);
    expect(gesture.mode).toBe("idle");
  });

  test("a side with no entry rubber-bands and never commits", () => {
    const steps = run(
      new SwipeGesture(),
      events("backCommit").map((event) => ({ ...event, back: event.back && false })),
    );
    const tracks = steps.filter((step) => step.kind === "track");
    expect(tracks.length).toBeGreaterThan(0);
    for (const step of tracks) {
      expect(step).toMatchObject({ available: false, armed: false });
      expect(step.kind === "track" && step.progress).toBeLessThan(SWIPE.rubber);
    }
    expect(steps.some((step) => step.kind === "commit")).toBe(false);
    expect(kinds(steps).at(-1)).toBe("cancel");
    expect(rubberBand(10)).toBeLessThan(SWIPE.rubber);
  });

  test("a vertical scroll is declined and its momentum stays with the page", () => {
    const gesture = new SwipeGesture();
    const steps = run(gesture, events("vertical"));
    expect(kinds(steps)).toEqual([]);
    const lift = events("vertical").findIndex((event) => event.phase === "ended");
    const declined = new SwipeGesture();
    run(declined, events("vertical").slice(0, lift));
    expect(declined.mode).toBe("declined");
  });

  test("a diagonal scroll is declined", () => {
    const gesture = new SwipeGesture();
    const list = events("diagonal");
    const steps = run(gesture, list.slice(0, -1));
    expect(kinds(steps)).toEqual([]);
    expect(gesture.mode).toBe("declined");
  });

  test("momentum events never start or extend a swipe", () => {
    const gesture = new SwipeGesture();
    const momentum = events("backCommit").filter((event) => event.momentum);
    const loud = momentum.map((event) => ({ ...event, dx: event.dx * 20 }));
    expect(kinds(run(gesture, loud))).toEqual([]);
    expect(gesture.mode).toBe("idle");
  });

  test("a new began while tracking cancels the old swipe and starts over", () => {
    const gesture = new SwipeGesture();
    const list = events("backCommit");
    const lift = list.findIndex((event) => event.phase === "ended");
    run(gesture, list.slice(0, lift));
    expect(gesture.mode).toBe("tracking");
    const step = gesture.feed({ phase: "began", momentum: false, dx: 0, dy: 0, time: 900 }, context());
    expect(step.kind).toBe("cancel");
    expect(gesture.mode).toBe("pending");
    // The new gesture is judged on its own motion: a vertical move now declines it.
    gesture.feed({ phase: "changed", momentum: false, dx: 0, dy: -12, time: 908 }, context());
    expect(gesture.mode).toBe("declined");
  });

  test("a cancelled phase while tracking springs back", () => {
    const gesture = new SwipeGesture();
    const list = events("backCommit");
    run(gesture, list.slice(0, 8));
    expect(gesture.feed({ phase: "cancelled", momentum: false, dx: 0, dy: 0, time: 200 }, context()).kind).toBe(
      "cancel",
    );
  });

  test("the page keeping the gesture (nested scroller, editable, selection) declines it", () => {
    const asked: string[] = [];
    const gesture = new SwipeGesture();
    const steps = run(
      gesture,
      events("backCommit").slice(0, 6),
      context({ keeps: (direction) => (asked.push(direction), true) }),
    );
    expect(kinds(steps)).toEqual([]);
    expect(asked).toEqual(["back"]);
    expect(gesture.mode).toBe("declined");
  });

  test("a swipe that interrupts a spring-back starts from where the content is", () => {
    const gesture = new SwipeGesture();
    const list = events("backCommit");
    const steps = run(gesture, list.slice(0, 4), context({ carry: 0.2 }));
    const first = steps.find((step) => step.kind === "track");
    expect(first?.kind === "track" && first.progress).toBeGreaterThan(0.2);
  });
});
