/** @jsxImportSource ../../kit/closed */
// A closed file (tsconfig.closed.json): no raw element, `style` or `className` compiles here.
// `chat.receiveTransition` / `default`: what MessageRow.tsx drew around a reply before slots, unchanged:
// the reply as it is, or in the prompt glass under the Messages presentation (AssistantPresentation).
// The words' own reveal stays RevealedMarkdown's.
import { AssistantPresentation } from "../../agent-session/acpmux/conversation/PresentationContext";
import type { ReceiveTransitionProps } from "./slot";

export function DefaultReplyArrival({ children }: ReceiveTransitionProps) {
  return <AssistantPresentation>{children}</AssistantPresentation>;
}
