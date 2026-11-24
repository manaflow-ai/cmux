// What a folded group of messages shows under the pointer ("Received 7 messages", the waiting group,
// an inbox notice of several threads; MessageGroupHead.tsx). Leo, 2026-11-07, on that hover as a wall
// of "<lane> (self-declared, unauthenticated)" names: "I feel like, the hover preview when you
// receive a lot of messages, this is not useful." It shows the newest message whole under its sender
// (each line's Markdown marks out, the broker's label out), then a hairline and the other senders,
// each once, newest first, with how many messages each sent: who, how many, and what the latest
// said, never a stack of rows cut to two lines. A sender's name is short (the name after its
// machine), with its family's mark and, when acpmux could not verify it, the small marker
// (UnverifiedMark.tsx), never words in the name. Four other senders at most, then "+N more"
// counting the rest of the messages. Leo, 2026-11-14, on that digest with a second sender's name
// and no way to read what it said: "this has no transparency at all + is not scrollable". The
// default is now `threads`: each sender once, newest first, with its count and its newest message
// whole, a hairline between, in a card that scrolls past the window's height (desktop.css
// .ui-tooltip.ui-card). The looks beside the default are gallery versions
// (AgentMessageRowKinds.gallery.tsx, `hover`; ReceivedMessages.gallery.ts, the card over a chat).
import { useContext } from "react";
import { useT } from "../i18n";
import { SenderMark } from "./IncomingMessageCard";
import { messagePreview, plainLine } from "./agentMessageRowModel";
import type { IncomingMessage } from "./incomingMessage";
import { withoutRelayLabelOfMessage } from "./relayEnvelope";
import { senderName } from "./senderIdentity";
import { UnverifiedMark } from "./UnverifiedMark";
import "./MessageGroupHover.css";
import {
  GroupHoverLookContext,
  hoverSenders,
  hoverThreads,
  shortSender,
  type GroupHoverList,
} from "./messageGroupHoverModel";
import { signed } from "../../../ui/Typography";

/// The most messages the `messages` and `lines` looks list before "+N more".
export const GROUP_HOVER_MAX = 5;

/// The most other senders the digest names before "+N more".
export const GROUP_HOVER_SENDERS = 4;

/// A message whole as it reads in the hover: the broker's label out, each line's Markdown marks out,
/// blank lines dropped, lines kept as lines (the card cuts it near twelve lines).
function wholeText(text: string): string {
  return withoutRelayLabelOfMessage(text)
    .split("\n")
    .map((line) => plainLine(line).trimEnd())
    .filter((line) => line.trim())
    .join("\n");
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

function Threads({ list }: { list: GroupHoverList }) {
  const t = useT();
  const threads = hoverThreads(list);
  // The newest sender and four others, as the digest names; "+N more" counts the rest's messages.
  const shown = threads.slice(0, GROUP_HOVER_SENDERS + 1);
  const counted = shown.reduce((sum, thread) => sum + thread.count, 0);
  const rest = Math.max(0, list.total - counted, threads.length > shown.length ? 1 : 0);
  return (
    <div className="cv-group-hover" data-look="threads">
      {shown.map((thread, index) => {
        const body = wholeText(thread.message.text);
        return (
          <div key={`${senderName(thread.message.name)}:${index}`} className="cv-group-hover__thread">
            <div className="cv-group-hover__who">
              <SenderWho message={thread.message} unverified={thread.unverified} />
              {thread.count > 1 && <span className="cv-group-hover__count">{thread.count}</span>}
            </div>
            {body && <div className="cv-group-hover__body">{body}</div>}
          </div>
        );
      })}
      {rest > 0 && <div className="cv-group-hover__more">{signed(t("tools.more", { n: rest }))}</div>}
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
  if (look === "threads") return <Threads list={list} />;
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
