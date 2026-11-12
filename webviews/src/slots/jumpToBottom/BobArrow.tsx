// `chat.jumpToBottom` / `bob`: while the agent works and the button shows, the arrow bobs gently toward
// the latest message once per breath, saying more is arriving below; idle, it rests. One transform loop
// on `--cmux-breath-period` (jumpToBottom.css), drawn only while both hold.
import { ArrowDown } from "../../agent-session/acpmux/conversation/icons";
import type { JumpToBottomProps } from "./slot";

export function BobArrow({ working }: JumpToBottomProps) {
  return (
    <span
      className="acpmux-jump-latest__arrow slot-jump"
      data-variant="bob"
      data-working={working ? "" : undefined}
      aria-hidden="true"
    >
      <span className="slot-jump__bob">
        <ArrowDown size={14} />
      </span>
    </span>
  );
}
