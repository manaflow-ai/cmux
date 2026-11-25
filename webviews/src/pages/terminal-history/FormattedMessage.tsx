import { AgentMessageBody } from "../../agent-session/acpmux/conversation/AgentMessageBody";
import { GuestActionsBoundary } from "../../agent-session/acpmux/conversation/GuestActionsBoundary";

/** The chat's own Markdown renderer and read-only action contexts, loaded on a formatted turn. */
export default function FormattedMessage({ text, at }: { text: string; at?: number }) {
  return (
    <GuestActionsBoundary>
      <AgentMessageBody text={text} messageAt={at} plainCode />
    </GuestActionsBoundary>
  );
}
