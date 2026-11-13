import { describe, expect, test } from "bun:test";
import { holdEntranceForFirstFrame } from "./entranceClock";

type Fake = {
  animationName?: string;
  playState: AnimationPlayState;
  currentTime: number | null;
  effect: { getComputedTiming: () => { endTime: number } };
  pause: () => void;
  play: () => void;
};

function fake(name: string | undefined, endTime = 80, currentTime = 40): Fake {
  const animation: Fake = {
    playState: "running",
    currentTime,
    effect: { getComputedTiming: () => ({ endTime }) },
    pause: () => void (animation.playState = "paused"),
    play: () => void (animation.playState = "running"),
  };
  if (name) animation.animationName = name;
  return animation;
}

function frames() {
  const queued = new Map<number, () => void>();
  let next = 1;
  return {
    queued,
    request: (run: () => void) => {
      queued.set(next, run);
      return next++;
    },
    cancel: (handle: number) => void queued.delete(handle),
    flush: () => {
      const runs = [...queued.values()];
      queued.clear();
      for (const run of runs) run();
    },
  };
}

const row = (animations: Fake[]) => ({ getAnimations: () => animations }) as unknown as Element;

describe("holdEntranceForFirstFrame", () => {
  test("holds the entrance through its first painted frame, then plays it", () => {
    const fade = fake("cv-enter-fade");
    const clock = frames();
    holdEntranceForFirstFrame(row([fade]), clock);
    expect(fade.playState).toBe("paused");
    expect(fade.currentTime).toBe(0);
    clock.flush();
    expect(fade.playState).toBe("paused");
    expect(fade.currentTime).toBe(0);
    clock.flush();
    expect(fade.playState).toBe("running");
    expect(fade.currentTime).toBe(0);
  });

  test("leaves other animations alone: infinite ones, unnamed ones, other keyframes", () => {
    const shimmer = fake("cv-enter", Infinity);
    const waapi = fake(undefined);
    const other = fake("cv-fold");
    const clock = frames();
    holdEntranceForFirstFrame(row([shimmer, waapi, other]), clock);
    expect([shimmer, waapi, other].map((animation) => animation.playState)).toEqual(["running", "running", "running"]);
    expect(clock.queued.size).toBe(0);
  });

  test("an unmount before the frame cancels the request", () => {
    const fade = fake("cv-enter");
    const clock = frames();
    const cancel = holdEntranceForFirstFrame(row([fade]), clock);
    cancel();
    expect(clock.queued.size).toBe(0);
  });

  test("an unmount after the first frame cancels the release", () => {
    const fade = fake("cv-enter");
    const clock = frames();
    const cancel = holdEntranceForFirstFrame(row([fade]), clock);
    clock.flush();
    cancel();
    expect(clock.queued.size).toBe(0);
    clock.flush();
    expect(fade.playState).toBe("paused");
  });
});
