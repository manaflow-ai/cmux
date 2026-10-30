// Chips inside another agent's message (conversation/IncomingMessageCard.tsx). A message from an
// agent on another machine names that machine's files, which this Mac never opens or reads: each
// is a chip with the machine's name in its tooltip, never a file of the same path here.
import { createContext, useContext } from "react";

export type MessageScope = {
  /// The machine the sender's files are on, when it is not this Mac: its name, or "" when the
  /// message came from another machine without one.
  host?: string;
};

export const MessageScopeContext = createContext<MessageScope | null>(null);

/// The agent message a chip draws in, or null in a reply.
export function useMessageScope(): MessageScope | null {
  return useContext(MessageScopeContext);
}
