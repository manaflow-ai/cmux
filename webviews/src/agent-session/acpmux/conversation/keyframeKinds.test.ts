import { describe, expect, test } from "bun:test";
import { keyframeKinds, setEffectKeyframes } from "./keyframeKinds";

/// A KeyframeEffect stand-in that counts its getKeyframes reads.
function effect(frames: Keyframe[]) {
  let current = frames;
  const fake = {
    reads: 0,
    getKeyframes() {
      fake.reads += 1;
      return current.map((frame) => ({ ...frame }));
    },
    setKeyframes(next: Keyframe[]) {
      current = next;
    },
  };
  return fake;
}

describe("keyframeKinds", () => {
  test("reads an effect's keyframes once for any number of asks", () => {
    const glide = effect([{ translate: "0 12px" }, { translate: "0 0" }]);
    for (let i = 0; i < 5; i++)
      expect(keyframeKinds(glide as unknown as KeyframeEffect)).toEqual({ translates: true, clips: false });
    expect(glide.reads).toBe(1);
  });

  test("tells a clip, a transform and a fade apart", () => {
    expect(keyframeKinds(effect([{ clipPath: "inset(0)" }]) as unknown as KeyframeEffect)).toEqual({
      translates: false,
      clips: true,
    });
    expect(keyframeKinds(effect([{ transform: "none" }]) as unknown as KeyframeEffect).translates).toBe(true);
    expect(keyframeKinds(effect([{ opacity: 0 }, { opacity: 1 }]) as unknown as KeyframeEffect)).toEqual({
      translates: false,
      clips: false,
    });
    expect(keyframeKinds(null)).toEqual({ translates: false, clips: false });
  });

  test("new keyframes set through setEffectKeyframes are read again", () => {
    const cut = effect([{ opacity: 1 }]);
    const asEffect = cut as unknown as KeyframeEffect;
    expect(keyframeKinds(asEffect).clips).toBe(false);
    setEffectKeyframes(asEffect, [{ clipPath: "inset(0 0 4px 0)" }, { clipPath: "inset(0)" }]);
    expect(keyframeKinds(asEffect).clips).toBe(true);
    expect(cut.reads).toBe(2);
  });
});
