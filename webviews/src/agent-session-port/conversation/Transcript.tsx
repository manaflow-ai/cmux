// Renders a conversation described as data (model.ts) with the presentational components.
// Compose the components directly when a screen needs something the model lacks.
import { EditedFilesCard, OpenElsewhereBanner } from "./cards";
import { Thread, type ThreadProps } from "./Thread";
import { Markdown } from "./Markdown";
import { AssistantMessage, Thinking, Timestamp, UserMessage } from "./messages";
import type { AssistantPart, Conversation, Message } from "./model";
import { TurnMessage } from "./TurnMessage";
import { Fragment } from "react";
import { separatorText, separatorTimes, turnMessages, type Clock } from "./timestamps";

function Part({ part }: { part: AssistantPart }) {
  switch (part.type) {
    case "markdown":
      return <Markdown>{part.source}</Markdown>;
    case "thinking": {
      const { type: _type, ...rest } = part;
      return <Thinking {...rest} />;
    }
    case "edited-files": {
      const { type: _type, ...rest } = part;
      return <EditedFilesCard {...rest} />;
    }
  }
}

/** All messages of a conversation, in order. Place inside a <Thread> (or use <Transcript>). */
export function Messages({ messages, clock }: { messages: Message[]; clock?: Clock }) {
  // Timestamp lines above turns (timestamps.ts); other messages break the adjacency.
  const lines = clock
    ? separatorTimes(
        messages.map((m) => (m.role === "turn" ? turnMessages(m.turn) : null)),
        clock.now,
      )
    : [];
  return (
    <>
      {messages.map((item, i) => {
        switch (item.role) {
          case "turn": {
            const { role: _role, ...props } = item;
            const at = lines[i];
            return (
              <Fragment key={item.turn.id}>
                {at != null && clock && <Timestamp>{separatorText(at, clock)}</Timestamp>}
                <TurnMessage {...props} />
              </Fragment>
            );
          }
          case "system":
            return <Timestamp key={i}>{item.text}</Timestamp>;
          case "user":
            return (
              <UserMessage key={i} actions={item.actions}>
                {item.text}
              </UserMessage>
            );
          case "assistant":
            return (
              <AssistantMessage key={i} actions={item.actions}>
                {item.parts.map((p, j) => (
                  <Part key={j} part={p} />
                ))}
              </AssistantMessage>
            );
        }
      })}
    </>
  );
}

export type TranscriptProps = Omit<ThreadProps, "children"> & { conversation: Conversation };

/**
 * A conversation in its real scroll container: the drop-in main column of a Codex thread.
 * The conversation's banner, when it has one, takes the composer's place; `scroll`, when
 * given, overrides the conversation's scroll position.
 */
export function Transcript({ conversation, composer, scroll, ...thread }: TranscriptProps) {
  const { banner } = conversation;
  return (
    <Thread
      {...thread}
      scroll={scroll ?? conversation.scroll}
      composer={
        banner ? (
          <OpenElsewhereBanner title={banner.title} body={banner.body} actions={banner.actions} />
        ) : (
          composer
        )
      }
    >
      <Messages messages={conversation.messages} clock={conversation.clock} />
    </Thread>
  );
}
