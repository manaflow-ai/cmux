// `chat.thinkingIndicator` / `default`: the live line's look before slots, so the default draws the
// same markup (Thinking.slot.test.tsx compares it to the pre-slot JSX). A light band in the theme
// accent sweeps across the dim word and the time (ShimmerText.tsx): two transform loops on
// `--cmux-shimmer-period` the compositor runs (conversation.css `.cv-shimmer__*`, shared with running
// rows, so the rules stay there). Reduce Motion and static status indicators hide the band.
//
// The markup is the live line's own (conversation/LiveShimmer.tsx). While this variant is the selected
// one, Thinking.tsx draws that component in place for the thinking word AND for each step, so the band
// is one element across them; this component draws the same look where the slot draws its default
// (the fallback of a variant that threw, and the gallery).
import { LiveShimmer } from "../../agent-session/acpmux/conversation/LiveShimmer";
import type { ThinkingIndicatorProps } from "./slot";

export function DefaultThinkingIndicator({ label, verbs, elapsed }: ThinkingIndicatorProps) {
  return <LiveShimmer label={label} verbs={verbs} elapsed={elapsed} />;
}
