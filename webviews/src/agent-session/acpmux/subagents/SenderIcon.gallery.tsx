// l10n-allow-file: gallery fixture names and messages, not shipped copy.
// One sender icon for every sender (SenderIcon.tsx): the model family's mark with a small badge in
// the session's own tone, so two Claude sessions read as Claude and as two (Leo, 2026-11-05: "I
// guess there's the thing about, okay, you have the icon, and then you have a smaller icon on the
// left or the right ... It's like you either have the model family be the big one or the small one,
// and then you have the, like, colored either robot symbol or the sort of, you know, the diamond
// symbol"). Each variant is one Settings > Agent Chat > Sender Icon look (senderIconLook.ts): the
// real received lines and a digest head of one sender, then the same four senders enlarged. Before:
// the badge off, the family's mark alone and the robot for a sender with none (today's lines).
// Reference: claude/live/transcript-tool-rows-and-task-list (the icon column).
import { useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { IncomingMessageLine } from "../conversation/IncomingMessageCard";
import type { IncomingMessage } from "../conversation/incomingMessage";
import { MessageGroupHead } from "../conversation/MessageGroupHead";
import { agentTone } from "./agentTones";
import { SenderIcon } from "./SenderIcon";
import {
  configureSenderIconLook,
  SENDER_ICON_BADGE_KEY,
  SENDER_ICON_CORNER_KEY,
  SENDER_ICON_LEAD_KEY,
} from "./senderIconLook";
import type { SenderIconLook } from "./senderIconLook";

const SENDERS: IncomingMessage[] = [
  {
    name: "grid-lane",
    sessionId: "s-grid",
    harness: "claude",
    text: "#2210 is green at its head; landing it now.",
    raw: "",
  },
  {
    name: "polish-coordinator",
    sessionId: "s-coordinator",
    harness: "claude",
    text: "Leo wants the digest row itself to open. Take it first.",
    raw: "",
  },
  {
    name: "build-box/review-lane",
    sessionId: "s-review",
    harness: "codex",
    text: "Review passed at e34ce27, no findings.",
    raw: "",
  },
  { name: "picker-lane", sessionId: "s-picker", text: "Picked up the handoff issue.", raw: "" },
];

type Props = { look: SenderIconLook };

function SenderIconLooks({ look }: Props) {
  // Each stage is its own frame: the look is set once, before any icon draws.
  useState(() =>
    configureSenderIconLook({
      [SENDER_ICON_LEAD_KEY]: look.lead,
      [SENDER_ICON_BADGE_KEY]: look.badge,
      [SENDER_ICON_CORNER_KEY]: look.corner,
    }),
  );
  return (
    <main className="sender-icon-gallery acpmux-conversation" data-gallery-capture="">
      <section className="cv-tools">
        <MessageGroupHead
          sender={SENDERS[0]}
          count="2 messages from 1 session"
          senders="grid-lane"
          open={false}
          bodyId="sender-icon-gallery-group"
          onToggle={() => undefined}
        />
        {SENDERS.map((message, index) => (
          <div key={message.sessionId} className="cv-incoming">
            <IncomingMessageLine id={`sender-icon-${index}`} message={message} onOpen={() => undefined} />
          </div>
        ))}
      </section>
      <section className="sender-icon-gallery__large" aria-label="The same senders, enlarged">
        {SENDERS.map((message) => (
          <figure key={message.sessionId}>
            <SenderIcon harness={message.harness} tone={agentTone(message.sessionId!)} size={32} fallback="agent.bot" />
            <figcaption>{message.name}</figcaption>
          </figure>
        ))}
      </section>
    </main>
  );
}

const variant = (look: SenderIconLook, note: string): ComponentVariant<Props> => ({ note, props: { look } });

export default componentEntry<Props>({
  id: "agent-pane.sender-icon",
  title: "Sender icons: the model family's mark and the session's badge",
  area: "Agent pane",
  pane: true,
  height: 300,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: [
    "agent-session/acpmux/subagents/SenderIcon.tsx",
    "agent-session/acpmux/subagents/SenderIcon.css",
    "agent-session/acpmux/subagents/senderIconLook.ts",
    "agent-session/acpmux/subagents/AgentIdentity.tsx",
  ],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../conversation/conversation.css"),
      import("./subagents.css"),
      import("./SenderIcon.gallery.css"),
    ]),
  load: async () => SenderIconLooks,
  keywords: ["sender", "icon", "badge", "diamond", "robot", "model", "family", "claude", "codex", "session", "tone"],
  variants: {
    "family-diamond-bottom-right": variant(
      { lead: "family", badge: "diamond", corner: "bottom-right" },
      "Chosen (the default): the family's mark big, the session's diamond small at its bottom right, in the session's tone. Two Claude sessions read as Claude and as two; a sender with no family draws its diamond alone.",
    ),
    "family-diamond-bottom-left": variant(
      { lead: "family", badge: "diamond", corner: "bottom-left" },
      "The diamond at the bottom left.",
    ),
    "family-diamond-top-right": variant(
      { lead: "family", badge: "diamond", corner: "top-right" },
      "The diamond at the top right.",
    ),
    "family-diamond-top-left": variant(
      { lead: "family", badge: "diamond", corner: "top-left" },
      "The diamond at the top left.",
    ),
    "family-robot-bottom-right": variant(
      { lead: "family", badge: "robot", corner: "bottom-right" },
      "The robot as the badge, at the bottom right.",
    ),
    "session-diamond-bottom-right": variant(
      { lead: "session", badge: "diamond", corner: "bottom-right" },
      "Reversed: the session's diamond big in its tone, the family's mark small at its bottom right.",
    ),
    "session-robot-bottom-right": variant(
      { lead: "session", badge: "robot", corner: "bottom-right" },
      "Reversed with the robot: the session's robot big, the family's mark small.",
    ),
    "before-no-badge": variant(
      { lead: "family", badge: "none", corner: "bottom-right" },
      "Before (Sender Badge: None): the family's mark alone, so two Claude sessions look the same, and a sender with no family draws the robot.",
    ),
  },
});
