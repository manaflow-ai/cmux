/// What an animation's keyframes animate, read once per effect.
///
/// `KeyframeEffect.getKeyframes()` builds a new array of new objects on every call, with each value
/// serialized again. The pinned live line asks it of every animation over the line on every draw,
/// several times each (pinnedLiveLine.ts `translatingOf`, `dropClipGlides`). In a long chat that was
/// 0.44 to 0.75 ms of a tool call's main-thread time (bench/transcript-replay.bench.ts PROFILE=1,
/// `getKeyframes` self time).
///
/// The kinds are kept by effect. A script effect's keyframes change only through `setKeyframes`, and
/// every call of it in the transcript goes through `setEffectKeyframes` below, which forgets that
/// effect's entry. A CSS animation or transition is a new Animation (so a new effect) when its rule changes.

export type KeyframeKinds = {
  /// It plays a translate (`translate` or `transform`).
  translates: boolean;
  /// It plays a clip (`clipPath`).
  clips: boolean;
};

const NONE: KeyframeKinds = { translates: false, clips: false };
const kinds = new WeakMap<AnimationEffect, KeyframeKinds>();

/// The kinds of `effect`'s keyframes: one `getKeyframes` read per effect for its life. O(1) after it.
export function keyframeKinds(effect: AnimationEffect | null | undefined): KeyframeKinds {
  if (!effect) return NONE;
  const known = kinds.get(effect);
  if (known) return known;
  const frames = (effect as KeyframeEffect).getKeyframes?.();
  if (!frames) return NONE;
  let translates = false;
  let clips = false;
  for (const frame of frames) {
    if ("translate" in frame || "transform" in frame) translates = true;
    if ("clipPath" in frame) clips = true;
  }
  const read = { translates, clips };
  kinds.set(effect, read);
  return read;
}

/// `effect.setKeyframes(frames)`, forgetting what its old keyframes animated.
export function setEffectKeyframes(effect: KeyframeEffect, frames: Keyframe[] | PropertyIndexedKeyframes | null) {
  kinds.delete(effect);
  effect.setKeyframes(frames);
}
