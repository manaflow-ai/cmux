// A conversation's face in the list and the header: a channel shows two of its people (the last
// author in front), as a group conversation does in a messenger; a direct conversation is the
// other member's avatar. A Chief's face carries its live state: a slow
// turning ring while it works, a small dot while it waits for me (Reduce Motion: a still ring).
import type { CSSProperties } from "react";
import { Avatar } from "./Avatar";
import type { ChiefState } from "./presence";
import type { HomeConversation } from "./types";

export function ConversationAvatar({
  conversation,
  channel,
  me,
  size,
  presence,
}: {
  conversation: HomeConversation;
  channel: boolean;
  me?: string;
  size: number;
  presence?: ChiefState;
}) {
  if (channel) {
    const members = conversation.participants.filter((p) => p.id !== me);
    const front = members.find((p) => p.id === conversation.lastAuthor) ?? members[0];
    const back = members.find((p) => p !== front);
    // Two faces at 64% of the tile, one at each corner; too small a tile keeps its sign.
    if (!front || size < 30)
      return (
        <span
          className="hc-face channel"
          style={{ width: size, height: size, "--face": `${size}px` } as CSSProperties}
          aria-hidden="true"
        >
          #
        </span>
      );
    const small = Math.round(size * 0.64);
    return (
      <span className="hc-face-pair" style={{ width: size, height: size }} aria-hidden="true">
        {back && <Avatar participant={back} size={small} />}
        <Avatar participant={front} size={small} />
      </span>
    );
  }
  const other = conversation.participants.find((p) => p.id !== me);
  return (
    <span className={`hc-face-wrap${presence ? ` ${presence}` : ""}`} style={{ width: size, height: size }}>
      <Avatar participant={other} size={size} />
      {presence === "working" && <span className="hc-ring" aria-hidden="true" />}
      {presence === "waiting" && <span className="hc-dot" aria-hidden="true" />}
    </span>
  );
}
