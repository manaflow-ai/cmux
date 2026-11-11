// `chat.thinkingIndicator` / `default`: the live line's look before slots, moved here unchanged, so the
// default draws the same markup (Thinking.slot.test.tsx compares it to the pre-slot JSX). A light band
// in the theme accent sweeps across the dim word and the time (ShimmerText.tsx): two transform loops on
// `--cmux-shimmer-period` the compositor runs (conversation.css `.cv-shimmer__*`, shared with running
// rows, so the rules stay there). Reduce Motion and static status indicators hide the band.
import { ShimmerText } from "../../agent-session/acpmux/conversation/ShimmerText";
import { useVerbSizes, type ThinkingIndicatorProps } from "./slot";

export function DefaultThinkingIndicator({ label, verbs, elapsed }: ThinkingIndicatorProps) {
  const sizes = useVerbSizes(verbs);
  return (
    <ShimmerText
      text={label}
      baseText={
        <span className="cv-status-verb">
          {sizes}
          <span className="cv-status-verb__word">{label}</span>
        </span>
      }
      lit={
        <>
          <span className="cv-shimmer__lit-label cv-status-verb" data-text={label}>
            {sizes}
          </span>
          {elapsed && <span className="cv-shimmer__lit-time" data-text={elapsed} />}
        </>
      }
    />
  );
}
