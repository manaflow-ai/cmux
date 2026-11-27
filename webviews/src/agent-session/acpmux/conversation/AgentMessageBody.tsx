// The body shared by messages sent to another agent and messages received from one.
// Keep the Markdown policy in this one component: message rows may choose their own
// disclosure and chrome, but they must agree on links, commits, images and timestamps.
import { Markdown, type MarkdownProps } from "./Markdown";

export type AgentMessageBodyProps = Pick<
  MarkdownProps,
  "githubRepository" | "commits" | "thumbnails" | "messageAt" | "linkIcon" | "plainCode"
> & {
  text: string;
};

/** Render an agent message with the same Markdown rules in either direction. */
export function AgentMessageBody({ text, ...markdown }: AgentMessageBodyProps) {
  return <Markdown {...markdown}>{text}</Markdown>;
}
