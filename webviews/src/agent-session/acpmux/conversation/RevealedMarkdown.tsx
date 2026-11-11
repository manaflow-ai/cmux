// A reply as it streams: the text flows in over display frames (StreamReveal) instead of in
// bursts, one per acpmux delta. The same element shows the reply before and after the stream
// ends, so nothing remounts when it settles.

import { Markdown } from "./Markdown";
import { MessageBoundary } from "./MessageBoundary";
import { useStreamReveal } from "./revealedMarkdownModel";
import type { ClaimCheck } from "../model";
/// An assistant reply, revealed over frames while it streams. A reply that fails to draw falls
/// back to its plain text (MessageBoundary), never taking the pane with it.
export function RevealedMarkdown({
  text,
  streaming,
  githubRepository,
  messageAt,
  artifactIdentity,
  artifactRevision,
  claims,
}: {
  text: string;
  claims?: readonly ClaimCheck[];
  streaming: boolean;
  githubRepository?: string;
  messageAt?: number;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  return (
    <MessageBoundary source={text}>
      <Revealed
        text={text}
        streaming={streaming}
        githubRepository={githubRepository}
        messageAt={messageAt}
        artifactIdentity={artifactIdentity}
        artifactRevision={artifactRevision}
        claims={claims}
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
}: {
  text: string;
  claims?: readonly ClaimCheck[];
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
    >
      {visible}
    </Markdown>
  );
}
