// Chips inside another agent's message (conversation/IncomingMessageCard.tsx) draw as openable as
// the host lets them (Leo 2026-10-21: "can you just enable all these"). A path outside the chat's
// folders is a chip like any other, with no lock, and its image loads as a thumbnail, when
// `agentPane.links.outsideRoots` opens such a path (`open`, the default): the lock is for a file
// this Mac cannot open. A message from an agent on another machine names that machine's files,
// which this Mac never opens or reads: each is a chip with the machine's name and a lock, never a
// file of the same path here.
import { createContext, useContext } from "react";

export type MessageScope = {
  /// The machine the sender's files are on, when it is not this Mac: its name, or "" when the
  /// message came from another machine without one.
  host?: string;
  /// What the agent wrote for each file name the card wrote out in full (messageFiles.ts), keyed by
  /// the full path as written out: a chip that draws as text shows the agent's own spelling.
  written?: ReadonlyMap<string, string>;
  /// The images drawn as thumbnails under the message's text: a mention of one in the text is a
  /// quiet link once its thumbnail shows (chips/imageShown.ts).
  pictured?: ReadonlySet<string>;
};

export const MessageScopeContext = createContext<MessageScope | null>(null);

/// The agent message a chip draws in, or null in a reply.
export function useMessageScope(): MessageScope | null {
  return useContext(MessageScopeContext);
}
