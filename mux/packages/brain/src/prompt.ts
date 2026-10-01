import type { Conversation, ID, LinkEvent, Message } from "@mux/protocol";
import type { InputItem } from "./model.ts";

export interface PromptContext {
  muxId: ID;
  conversation: Conversation;
  /** Memory `wake` output: what the mux remembers beyond this conversation. */
  memory?: string;
  /** Messages of the conversation to show raw, newest last. */
  recent?: number;
  now?: Date;
}

export function instructions(ctx: PromptContext): string {
  const me = ctx.conversation.participants.find((p) => p.id === ctx.muxId);
  const others = ctx.conversation.participants
    .filter((p) => p.id !== ctx.muxId)
    .map((p) => `${p.displayName} (${p.kind})`)
    .join(", ");
  return [
    `You are ${me?.displayName ?? "mux"}, an orchestrator agent inside a Messages-style chat.`,
    `This conversation is "${ctx.conversation.title}" with ${others || "nobody else"}.`,
    "Reply like a capable colleague texting: short, direct, no headings. Use plain text.",
    "You do real work through your tools: spawn and steer coding agents on the user's machines,",
    "remember things, and message people. Say what you did and what happens next.",
    "Your final answer is posted to the chat automatically. Use mux.messages.send only for progress",
    "during long work, never to say what your final answer will say.",
    `Current time: ${(ctx.now ?? new Date()).toISOString()}.`,
    ctx.memory ? `\nWhat you remember:\n${ctx.memory}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

/** The conversation as model input: my messages are assistant turns, others are user turns. */
export function conversationInput(ctx: PromptContext): InputItem[] {
  const names = new Map(ctx.conversation.participants.map((p) => [p.id, p.displayName]));
  const messages = ctx.conversation.messages.slice(-(ctx.recent ?? 60));
  return messages
    .filter((m) => !m.retractedAt)
    .map((m) =>
      m.senderId === ctx.muxId
        ? { role: "assistant" as const, content: messageText(m) }
        : {
            role: "user" as const,
            content: `${names.get(m.senderId) ?? m.senderId}: ${messageText(m)}`,
          },
    );
}

export function messageText(message: Message): string {
  return message.parts
    .map((part) => {
      switch (part.type) {
        case "text":
          return part.text;
        case "link":
          return part.url;
        case "attachment":
          return `[${part.attachment.kind}: ${part.attachment.fileName}]`;
        case "location":
          return `[location: ${part.title ?? `${part.latitude},${part.longitude}`}]`;
      }
    })
    .join("\n");
}

/** An agent event as a developer turn the mux reacts to. */
export function eventInput(event: LinkEvent): InputItem {
  const header =
    event.kind === "turn_end"
      ? `Agent "${event.name}" (${event.sessionId}) finished a turn: ${event.status}${event.stopReason ? ` (${event.stopReason})` : ""}.\nIts reply:\n${event.reply || "(empty)"}`
      : `Agent "${event.name}" (${event.sessionId}) is waiting for permission: ${event.title} (permission ${event.permissionId}).`;
  return {
    role: "developer",
    content: `${header}\n\nTell the people in this conversation what they need to know, briefly, and take any next step yourself. If nothing is worth saying, answer with an empty message.`,
  };
}
