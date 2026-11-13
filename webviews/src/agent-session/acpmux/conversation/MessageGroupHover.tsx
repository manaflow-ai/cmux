// What a folded group of messages shows under the pointer ("Received 7 messages", the waiting group,
// an inbox notice of several threads; MessageGroupHead.tsx). Leo, 2026-11-07, on that hover as a wall
// of "<lane> (self-declared, unauthenticated)" names: "I feel like, the hover preview when you
// receive a lot of messages, this is not useful." It shows the newest message whole under its sender
// (each line's Markdown marks out, the broker's label out), then a hairline and the other senders,
// each once, newest first, with how many messages each sent: who, how many, and what the latest
// said, never a stack of rows cut to two lines. A sender's name is short (the name after its
// machine), with its family's mark and, when acpmux could not verify it, the small marker
// (UnverifiedMark.tsx), never words in the name. Four other senders at most, then "+N more"
// counting the rest of the messages. The looks beside the default are gallery versions
// (AgentMessageRowKinds.gallery.tsx, `hover`).
import { createContext, useContext } from "react";
import { useT } from "../i18n";
import { SenderMark } from "./IncomingMessageCard";
import { messagePreview, plainLine } from "./agentMessageRowModel";
import type { IncomingMessage } from "./incomingMessage";
import type { InboxThread } from "./inboxNotice";
import { withoutRelayLabelOfMessage } from "./relayEnvelope";
import { senderName } from "./senderIdentity";
import { UnverifiedMark } from "./UnverifiedMark";
import "./MessageGroupHover.css";
import { signed } from "../../../ui/Typography";

/// How the hover lays its messages out. `digest`, the default: the newest message whole, then the
/// other senders with their counts. `messages`: each message's sender, then two lines of it, five
/// at most. `lines`: one line each, "sender  first line". `names`: the senders only, each once,
/// with their marks (the list it was, without the noise).
export type GroupHoverLook = "digest" | "messages" | "lines" | "names";
export const GroupHoverLookContext = createContext<GroupHoverLook>("digest");

/// The most messages the `messages` and `lines` looks list before "+N more".
export const GROUP_HOVER_MAX = 5;

/// The most other senders the digest names before "+N more".
export const GROUP_HOVER_SENDERS = 4;

/// A sender's short name: the part after its machine ("gcp-agent-lane-1/ux-owner" reads "ux-owner").
export const shortSender = (name: string) => senderName(name).split("/").at(-1)?.trim() || senderName(name);

/// What a group's hover lists: its messages, newest first, and how many messages the group holds in
/// all, so "+N more" counts the true rest (a thread that held only its preview is one line for its
/// whole count). `counts[i]`, when given, is how many messages `messages[i]` stands for (one when
/// not given), so the digest counts each sender's true share.
export type GroupHoverList = { messages: readonly IncomingMessage[]; total: number; counts?: readonly number[] };

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
  const listed: { message: IncomingMessage; at?: number; order: number; count: number }[] = [];
  let total = 0;
  messages.forEach((message, index) => {
    if (!message) return;
    const at = message.at ?? ats[index];
    const count = Math.max(1, counts[index] ?? 1);
    listed.push({ message, ...(at !== undefined && { at }), order: index, count });
    total += count;
  });
  listed.sort((a, b) =>
    a.at !== undefined && b.at !== undefined ? b.at - a.at || b.order - a.order : b.order - a.order,
  );
  return { messages: listed.map((entry) => entry.message), total, counts: listed.map((entry) => entry.count) };
}

/// An inbox notice's hover: every message of every thread, newest first by when acpmux recorded it
/// (`at`), then the untimed ones by the notice's order, the later first; a thread that held only its preview is one line that counts
/// the thread's whole count (Leo, 2026-11-07, on a "Received 7 messages" hover that listed one).
export function inboxHover(threads: readonly InboxThread[]): GroupHoverList {
  const entries: { message: IncomingMessage; at?: number; order: number; count: number }[] = [];
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
          count: 1,
        });
      }
      total += Math.max(thread.count, thread.messages.length);
    } else {
      entries.push({
        message: { ...sent(newest), text: thread.preview, ...(thread.unverified && { unverified: true as const }) },
        order: entries.length,
        count: Math.max(1, thread.count),
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
  return { messages: entries.map((entry) => entry.message), total, counts: entries.map((entry) => entry.count) };
}

/// A message whole as it reads in the hover: the broker's label out, each line's Markdown marks out,
/// blank lines dropped, lines kept as lines (the card cuts it near twelve lines).
function wholeText(text: string): string {
  return withoutRelayLabelOfMessage(text)
    .split("\n")
    .map((line) => plainLine(line).trimEnd())
    .filter((line) => line.trim())
    .join("\n");
}

/// The digest's other senders: each once, newest first, with how many messages they sent; the
/// newest sender's earlier messages count under their own name.
export function hoverSenders(list: GroupHoverList): { message: IncomingMessage; count: number; unverified: boolean }[] {
  const [newest, ...others] = list.messages;
  if (!newest) return [];
  const senders: { message: IncomingMessage; count: number; unverified: boolean }[] = [];
  const index = new Map<string, number>();
  const add = (message: IncomingMessage, count: number) => {
    const key = senderName(message.name);
    const at = index.get(key);
    if (at === undefined) {
      index.set(key, senders.length);
      senders.push({ message, count, unverified: message.unverified === true });
      return;
    }
    const sender = senders[at]!;
    sender.count += count;
    sender.unverified ||= message.unverified === true;
  };
  // A newest line that stands for several (a thread that held only its preview): the rest are that
  // sender's earlier messages.
  const newestRest = Math.max(1, list.counts?.[0] ?? 1) - 1;
  if (newestRest > 0) add(newest, newestRest);
  others.forEach((message, offset) => add(message, Math.max(1, list.counts?.[offset + 1] ?? 1)));
  return senders;
}

function SenderWho({ message, unverified }: { message: IncomingMessage; unverified: boolean }) {
  return (
    <>
      <span className="cv-group-hover__mark" aria-hidden="true">
        <SenderMark message={message} />
      </span>
      <span className="cv-group-hover__name">{shortSender(message.name)}</span>
      {unverified && <UnverifiedMark program={message.program} claimed={message.name} />}
    </>
  );
}

function Digest({ list }: { list: GroupHoverList }) {
  const t = useT();
  const newest = list.messages[0];
  if (!newest) return null;
  const senders = hoverSenders(list);
  const shown = senders.slice(0, GROUP_HOVER_SENDERS);
  const counted = Math.max(1, list.counts?.[0] ?? 1) + shown.reduce((sum, sender) => sum + sender.count, 0);
  const rest = Math.max(0, list.total - counted, senders.length > shown.length ? 1 : 0);
  const body = wholeText(newest.text);
  return (
    <div className="cv-group-hover" data-look="digest">
      <div className="cv-group-hover__newest">
        <div className="cv-group-hover__who">
          <SenderWho message={newest} unverified={newest.unverified === true} />
        </div>
        {body && <div className="cv-group-hover__body">{body}</div>}
      </div>
      {shown.length > 0 && (
        <div className="cv-group-hover__senders">
          {shown.map((sender, index) => (
            <span key={`${senderName(sender.message.name)}:${index}`} className="cv-group-hover__sender">
              <SenderWho message={sender.message} unverified={sender.unverified} />
              {sender.count > 1 && <span className="cv-group-hover__count">{sender.count}</span>}
            </span>
          ))}
          {rest > 0 && <span className="cv-group-hover__more">{t("tools.more", { n: rest })}</span>}
        </div>
      )}
    </div>
  );
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
  if (look === "digest") return <Digest list={list} />;
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
              {message.unverified && <UnverifiedMark program={message.program} claimed={message.name} />}
              {look === "lines" && preview && <span className="cv-group-hover__line">{preview}</span>}
            </div>
            {look === "messages" && preview && <div className="cv-group-hover__text">{preview}</div>}
          </div>
        );
      })}
      {rest > 0 && <div className="cv-group-hover__more">{signed(t("tools.more", { n: rest }))}</div>}
    </div>
  );
}
