// `chat.jumpToBottom` / `nudge`: the arrow drops into the circle as the button appears, and dips toward
// the latest message while it is pressed, a click you can see. Two transform transitions keyed off the
// button's own `data-shown` and `:active` (jumpToBottom.css); no loop.
import { ArrowDown } from "../../agent-session/acpmux/conversation/icons";
import type { JumpToBottomProps } from "./slot";

export function NudgeArrow(_props: JumpToBottomProps) {
  return (
    <span className="acpmux-jump-latest__arrow slot-jump" data-variant="nudge" aria-hidden="true">
      <span className="slot-jump__nudge">
        <ArrowDown size={14} />
      </span>
    </span>
  );
}
