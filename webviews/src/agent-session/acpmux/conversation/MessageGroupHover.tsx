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
import { messagePreview } from "./agentMessageRowModel";
import type { IncomingMessage } from "./incomingMessage";
import type { InboxThread } from "./inboxNotice";
import { withoutRelayLabelOfMessage } from "./relayEnvelope";
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

/// What a group's hover lists: its messages, newest first, and how many messages the group holds in
/// all, so "+N more" counts the true rest (a thread that held only its preview is one line for its
/// whole count).
export type GroupHoverList = { messages: readonly IncomingMessage[]; total: number };

/// A group's hover from its members, oldest first; `counts[i]` is how many messages member i stands
/// for (a preview-only inbox delivery stands for its thread's count), one when not given; `ats[i]`
/// is member i's row time. Newest first by when each message came (its own `at`, an inbox
/// message's, else its row's), never by the members' order alone: an inbox notice lists its
/// threads in its own order. A tie, or a member with no time, keeps the later member first.
export function hoverMessages(
  messages: readonly (IncomingMessage | undefined)[],
  counts: readonly (number | undefined)[] = [],
  ats: readonly (number | undefined)[] = [],
): GroupHoverList {
  const listed: { message: IncomingMessage; at?: number; order: number }[] = [];
  let total = 0;
  messages.forEach((message, index) => {
    if (!message) return;
    const at = message.at ?? ats[index];
    listed.push({ message, ...(at !== undefined && { at }), order: index });
    total += Math.max(1, counts[index] ?? 1);
  });
  listed.sort((a, b) =>
    a.at !== undefined && b.at !== undefined ? b.at - a.at || b.order - a.order : b.order - a.order,
  );
  return { messages: listed.map((entry) => entry.message), total };
}

/// An inbox notice's hover: every message of every thread, newest first by when acpmux recorded it
/// (`at`), then the untimed ones by the notice's order, the later first; a thread that held only its preview is one line that counts
/// the thread's whole count (Leo, 2026-11-07, on a "Received 7 messages" hover that listed one).
export function inboxHover(threads: readonly InboxThread[]): GroupHoverList {
  const entries: { message: IncomingMessage; at?: number; order: number }[] = [];
  let total = 0;
  for (const thread of threads) {
    const newest = thread.messages?.at(-1)?.from || thread.from.at(-1) || "";
    const session = thread.fromSession ?? thread.sender?.session;
    const sent = (name: string) => ({
      name,
      raw: "",
      // The thread's session and family are its newest sender's: another sender's are its own.
      ...(name === newest && session && { sessionId: session }),
      ...(name === newest && thread.fromHarness && { harness: thread.fromHarness }),
    });
    if (thread.messages?.length) {
      for (const message of thread.messages) {
        const own = message.sender?.session;
        entries.push({
          message: {
            ...sent(message.from || newest),
            text: message.text,
            ...(own && { sessionId: own }),
            ...(message.harness && { harness: message.harness }),
            ...(message.unverified && { unverified: true as const }),
          },
          ...(message.at !== undefined && { at: message.at }),
          order: entries.length,
        });
      }
      total += Math.max(thread.count, thread.messages.length);
    } else {
      entries.push({
        message: { ...sent(newest), text: thread.preview, ...(thread.unverified && { unverified: true as const }) },
        order: entries.length,
      });
      total += Math.max(1, thread.count);
    }
  }
  // Newest first: the messages acpmux timed by their time (a tie, the later in the notice first),
  // then those it did not (a thread's preview), the later in the notice first.
  entries.sort((a, b) => {
    if (a.at !== undefined && b.at !== undefined) return b.at - a.at || b.order - a.order;
    if (a.at !== undefined) return -1;
    if (b.at !== undefined) return 1;
    return b.order - a.order;
  });
  return { messages: entries.map((entry) => entry.message), total };
}

/// A message's first lines as they read, for two lines in the hover: each line's Markdown marks out
/// (messagePreview), the broker's label out, joined.
function hoverText(text: string): string {
  return withoutRelayLabelOfMessage(text)
    .split("\n")
    .filter((line) => line.trim())
    .slice(0, 3)
    .map((line) => messagePreview(line))
    .join(" ");
}

export function MessageGroupHover({ list }: { list: GroupHoverList }) {
  const t = useT();
  const messages = list.messages;
  const look = useContext(GroupHoverLookContext);
  const shown =
    look === "names"
      ? messages.filter((message, index) => messages.findIndex((m) => m.name === message.name) === index)
      : messages;
  const listed = shown.slice(0, GROUP_HOVER_MAX);
  // The names look lists each sender once; the others count every message the group holds.
  const rest = (look === "names" ? shown.length : Math.max(list.total, shown.length)) - listed.length;
  return (
    <div className="cv-group-hover" data-look={look}>
      {listed.map((message, index) => {
        const preview =
          look === "messages" ? hoverText(message.text) : messagePreview(withoutRelayLabelOfMessage(message.text));
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
