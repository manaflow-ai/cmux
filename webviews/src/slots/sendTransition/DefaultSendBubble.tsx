// `chat.sendTransition` / `default`: the bubble UserBubble.tsx drew before slots, moved here unchanged
// (Slots.defaults.test.tsx compares it to the pre-slot JSX). Its entrance is conversation.css's send
// motion on the row, at the scale's send step (0 today: the prompt lands at once).
import type { SendTransitionProps } from "./slot";

export function DefaultSendBubble({ children }: SendTransitionProps) {
  return <div className="ui-glass cv-user__bubble selectable">{children}</div>;
}
