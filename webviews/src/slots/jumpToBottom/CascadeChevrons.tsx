// `chat.jumpToBottom` / `cascade`: two small arrows stacked in the circle; while the agent works they rest
// dim and a lit arrow steps from the upper place to the lower one, a cascade pointing down. One stepped
// transform loop on `--cmux-spinner-period` (jumpToBottom.css), never a fade; idle, both rest at full
// strength and the lit arrow is hidden.
import { ArrowDown } from "../../agent-session/acpmux/conversation/icons";
import type { JumpToBottomProps } from "./slot";

const STEPS = [0, 1] as const;

export function CascadeChevrons({ working }: JumpToBottomProps) {
  return (
    <span
      className="acpmux-jump-latest__arrow slot-jump slot-jump__cascade"
      data-variant="cascade"
      data-working={working ? "" : undefined}
      aria-hidden="true"
    >
      {STEPS.map((step) => (
        <span key={step} className="slot-jump__step" data-step={step}>
          <ArrowDown size={12} />
        </span>
      ))}
      <span className="slot-jump__step slot-jump__lit">
        <ArrowDown size={12} />
      </span>
    </span>
  );
}
