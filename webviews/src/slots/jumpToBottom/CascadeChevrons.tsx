// `chat.jumpToBottom` / `cascade`: two small arrows stacked in the circle; while the agent works the
// upper one fades and the lower one lights in turn, a cascade pointing down. Opacity beats on
// `--cmux-spinner-period` (jumpToBottom.css); idle, both rest at full strength.
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
          <ArrowDown size={10} />
        </span>
      ))}
    </span>
  );
}
