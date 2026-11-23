import { afterEach, expect, test } from "bun:test";
import { activityCue, headerMotionOf, motionCues, motionMorphs, motionSprings } from "./headerMotion";
import { headerState, resetHeaderStateForTests, setHeaderState } from "./headerState";

afterEach(() => resetHeaderStateForTests());

test("the header stays still unless the App picks a motion style", () => {
  expect(headerState().headerMotion).toBe("still");
  expect(headerMotionOf(undefined)).toBe("still");
  expect(headerMotionOf("bouncy")).toBe("still");
  setHeaderState({ headerMotion: "animated-morph", version: 1 });
  expect(headerState().headerMotion).toBe("animated-morph");
  // A push that leaves it out keeps it.
  setHeaderState({ pinned: true, version: 2 });
  expect(headerState().headerMotion).toBe("animated-morph");
  setHeaderState({ headerMotion: "still", version: 3 });
  expect(headerState().headerMotion).toBe("still");
});

test("each style adds to the one before it, and still adds nothing", () => {
  expect([motionCues("still"), motionSprings("still"), motionMorphs("still")]).toEqual([false, false, false]);
  expect([motionCues("animated-cue"), motionSprings("animated-cue"), motionMorphs("animated-cue")]).toEqual([
    true,
    false,
    false,
  ]);
  expect([motionCues("animated-spring"), motionSprings("animated-spring"), motionMorphs("animated-spring")]).toEqual([
    true,
    true,
    false,
  ]);
  expect([motionCues("animated-morph"), motionSprings("animated-morph"), motionMorphs("animated-morph")]).toEqual([
    true,
    true,
    true,
  ]);
});

test("the activity dot shows only while there is work, only on Changes", () => {
  expect(activityCue(["changes", "terminal"], { working: false, hasChanges: false })).toBeUndefined();
  expect(activityCue(["changes", "terminal"], { working: true, hasChanges: true })).toEqual({
    on: "changes",
    cue: "working",
  });
  expect(activityCue(["changes", "terminal"], { working: false, hasChanges: true })).toEqual({
    on: "changes",
    cue: "pending",
  });
  // Only Changes carries it: a dot on any other icon would read as that icon's state.
  expect(activityCue(["terminal", "browser"], { working: true, hasChanges: false })).toBeUndefined();
});
