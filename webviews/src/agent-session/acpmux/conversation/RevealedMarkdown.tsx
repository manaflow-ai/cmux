// A reply as it streams: each chunk's text shows in the commit that brings it, once per display
// frame, and its newest words fade in (useStreamReveal). The same element shows the reply before and
// after the stream ends, so nothing remounts when it settles.

import { Markdown } from "./Markdown";
import { MessageBoundary } from "./MessageBoundary";
import { useStreamReveal } from "./revealedMarkdownModel";
import type { ClaimCheck } from "../model";
/// An assistant reply, its newest words fading in while it streams. A reply that fails to draw falls
/// back to its plain text (MessageBoundary), never taking the pane with it.
export function RevealedMarkdown({
  text,
  streaming,
  githubRepository,
  messageAt,
  artifactIdentity,
  artifactRevision,
  claims,
  className,
}: {
  text: string;
  claims?: readonly ClaimCheck[];
  /** Classes beside `cv-md` (a reply's `cv-reply`, conversation.css). */
  className?: string;
  streaming: boolean;
  githubRepository?: string;
  messageAt?: number;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  return (
    <MessageBoundary source={text}>
      <Revealed
        // A recreated reply gets a fresh reveal loop; unmount cancels the old queued frame.
        // Keep this key separate from artifactIdentity, which must remain the original row ID.
        key={`${artifactIdentity ?? ""}:${messageAt ?? ""}`}
        text={text}
        streaming={streaming}
        githubRepository={githubRepository}
        messageAt={messageAt}
        artifactIdentity={artifactIdentity}
        artifactRevision={artifactRevision}
        claims={claims}
        className={className}
      />
    </MessageBoundary>
  );
}

function Revealed({
  text,
  streaming,
  githubRepository,
  messageAt,
  artifactIdentity,
  artifactRevision,
  claims,
  className,
}: {
  text: string;
  claims?: readonly ClaimCheck[];
  /** Classes beside `cv-md` (a reply's `cv-reply`, conversation.css). */
  className?: string;
  streaming: boolean;
  githubRepository?: string;
  messageAt?: number;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  const { visible, fresh, now } = useStreamReveal(text, streaming);
  // Marks draw on the whole reply only: a phrase still revealing would move under its mark.
  const whole = !streaming && visible.length === text.length;
  // Until all of it shows, the reply draws as streaming: the frame after the stream ends still
  // lacks the last word, and parsed as finished, a span that word closes showed its raw Markdown.
  return (
    <Markdown
      streaming={streaming || visible.length < text.length}
      fresh={fresh}
      now={now}
      githubRepository={githubRepository}
      messageAt={messageAt}
      artifactIdentity={artifactIdentity}
      artifactRevision={artifactRevision}
      claims={whole ? claims : undefined}
      className={className}
    >
      {visible}
    </Markdown>
  );
}
