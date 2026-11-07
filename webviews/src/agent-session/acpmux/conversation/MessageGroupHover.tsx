// What a folded group of messages shows under the pointer ("Received 7 messages", the waiting group,
// an inbox notice of several threads; MessageGroupHead.tsx). Leo, 2026-11-07, on that hover as a wall
// of "<lane> (self-declared, unauthenticated)" names: "I feel like, the hover preview when you
// receive a lot of messages, this is not useful." It shows the messages, newest first: each sender
// once per message, short (the name after its machine), with its family's mark and, when acpmux could
// not verify it, the small marker (UnverifiedMark.tsx), never words in the name; then the first line
// or two of what it said (messagePreview, the broker's label out). Five at most, then "+N more".
// The looks beside the default are gallery versions (AgentMessageRowKinds.gallery.tsx, `hover`).
import { createContext, useContext } from "react";
import { useT } from "../i18n";
import { SenderMark } from "./IncomingMessageCard";
import { messagePreview } from "./AgentMessageRow";
import type { IncomingMessage } from "./incomingMessage";
import { withoutRelayLabel } from "./relayEnvelope";
import { senderName } from "./senderIdentity";
import { UnverifiedMark } from "./UnverifiedMark";
import "./MessageGroupHover.css";

/// How the hover lays its messages out. `messages`, the default: the sender's line, then two lines
/// of the message under it. `lines`: one line each, "sender  first line". `names`: the senders only,
/// each once, with their marks (the list it was, without the noise).
export type GroupHoverLook = "messages" | "lines" | "names";
export const GroupHoverLookContext = createContext<GroupHoverLook>("messages");

/// The most messages the hover lists before "+N more".
export const GROUP_HOVER_MAX = 5;

/// A sender's short name: the part after its machine ("gcp-agent-lane-1/ux-owner" reads "ux-owner").
export const shortSender = (name: string) => senderName(name).split("/").at(-1)?.trim() || senderName(name);

/// The messages a group's hover lists, newest first, from its members oldest first.
export function hoverMessages(messages: readonly (IncomingMessage | undefined)[]): IncomingMessage[] {
  return messages.filter((message): message is IncomingMessage => Boolean(message)).reverse();
}

/// A message's first lines as they read, for two lines in the hover: each line's Markdown marks out
/// (messagePreview), the broker's label out, joined.
function hoverText(text: string): string {
  return withoutRelayLabel(text)
    .split("\n")
    .filter((line) => line.trim())
    .slice(0, 3)
    .map((line) => messagePreview(line))
    .join(" ");
}

export function MessageGroupHover({ messages }: { messages: readonly IncomingMessage[] }) {
  const t = useT();
  const look = useContext(GroupHoverLookContext);
  const shown =
    look === "names"
      ? messages.filter((message, index) => messages.findIndex((m) => m.name === message.name) === index)
      : messages;
  const listed = shown.slice(0, GROUP_HOVER_MAX);
  const rest = shown.length - listed.length;
  return (
    <div className="cv-group-hover" data-look={look}>
      {listed.map((message, index) => {
        const preview = look === "messages" ? hoverText(message.text) : messagePreview(withoutRelayLabel(message.text));
        return (
          <div key={`${message.msgId ?? ""}:${index}`} className="cv-group-hover__item">
            <div className="cv-group-hover__who">
              <span className="cv-group-hover__mark" aria-hidden="true">
                <SenderMark message={message} />
              </span>
              <span className="cv-group-hover__name">{shortSender(message.name)}</span>
              {message.unverified && <UnverifiedMark />}
              {look === "lines" && preview && <span className="cv-group-hover__line">{preview}</span>}
            </div>
            {look === "messages" && preview && <div className="cv-group-hover__text">{preview}</div>}
          </div>
        );
      })}
      {rest > 0 && <div className="cv-group-hover__more">{t("tools.more", { n: rest })}</div>}
    </div>
  );
}
