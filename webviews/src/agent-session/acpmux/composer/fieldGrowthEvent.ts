/// The prompt field's growth motion, told to what moves with it (fieldGrowth.ts). Dispatched on the
/// field (`.acpmux-md-field`), bubbling, in the edit's own task as the motion starts or retargets.
/// The transcript (VirtualTranscript) takes the field's end height into its room at once, in one
/// render, and moves its rows from where they are drawn on the same curve and clock, so no frame of
/// the motion renders it again.
export const FIELD_GROWTH_EVENT = "acpmux-field-growth";

/// An attachment tile in the text took a new shape with no edit (its header read, its loading tile
/// turned into its chip, its chip dropped before its node goes): dispatched on the tile's node, bubbling,
/// in the render's own commit (inlineAttachments.tsx), so the field's move (fieldGrowth.ts) starts
/// before the frame lays out, as an edit's does.
export const TILE_SHAPE_EVENT = "acpmux-tile-shape";

export type FieldGrowthDetail = {
  /// The height the field lands on (px); its drawn height minus this is what the stack has yet to grow.
  to: number;
  /// The motion's curve as progress points from 0 to 1, run linearly over `duration` (the spring
  /// arms); unset, a two-point move on `easing`.
  progress?: readonly number[];
  easing: string;
  duration: number;
  /// The field's own animation: what moves with it starts on its start time (the same frame).
  animation: Animation;
  /// Set for a change of the value from outside (a send clearing a tall prompt): the field lands at
  /// once, as such a change always did, unless a listener calls `claim` during the dispatch and plays
  /// `animation` on its own clock (VirtualTranscript: the send's one motion, motionTransaction.ts).
  outside?: { claim: () => void };
};

export type FieldGrowthEvent = CustomEvent<FieldGrowthDetail>;

/// `delta` px to 0 on the growth's curve, as translate keyframes (what moves with the field).
export function growthTranslate(detail: FieldGrowthDetail, delta: number): Keyframe[] {
  const progress = detail.progress ?? [0, 1];
  return progress.map((value) => ({ translate: `0 ${delta * (1 - value)}px` }));
}
