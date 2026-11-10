// `chat.jumpToBottom` / `default`: the mark the button drew before slots, moved here unchanged (a static
// down arrow; JumpToBottom.slot.test.tsx compares it to the pre-slot JSX). The working state is the
// transcript's shared spinner, so the arrow never moves (conversation.css `.acpmux-jump-latest__arrow`).
import { ArrowDown } from "../../agent-session/acpmux/conversation/icons";
import type { JumpToBottomProps } from "./slot";

export function DefaultJumpArrow(_props: JumpToBottomProps) {
  return (
    <span className="acpmux-jump-latest__arrow" aria-hidden="true">
      <ArrowDown size={14} />
    </span>
  );
}
