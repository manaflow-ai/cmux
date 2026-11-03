// Chief messages stay outside the run disclosure, with the agent pane's message rows.
import { memo, useContext } from "react";
import { useT } from "../../agent-session/acpmux/i18n";
import { AgentMessageRow, messagePreview } from "../../agent-session/acpmux/conversation/AgentMessageRow";
import { AgentMessageBody } from "../../agent-session/acpmux/conversation/AgentMessageBody";
import { AgentNamesContext, recipientName } from "../../agent-session/acpmux/conversation/agentNames";
import { MessageCard } from "../../agent-session/acpmux/conversation/MessageCard";
import { Envelope } from "../../agent-session/acpmux/conversation/icons";
import { useTranscriptDisclosure } from "../../agent-session/acpmux/conversation/transcriptDisclosure";
import type { RunAgentMessage } from "./runMessages";

export const RunMessage = memo(function RunMessage({
  id,
  message,
  at,
  author,
}: {
  id: string;
  message: RunAgentMessage;
  at: number;
  author: string;
}) {
  const t = useT();
  const names = useContext(AgentNamesContext);
  const [open, setOpen] = useTranscriptDisclosure(`chief-report:${id}`);
  if ("sent" in message)
    return (
      <MessageCard
        item={{ ...message.item, tool: { ...message.item.tool!, id } }}
        message={message.sent}
        messageAt={at}
      />
    );
  const from = recipientName(message.from, names) ?? message.from;
  return (
    <AgentMessageRow
      direction="received"
      icon={<Envelope />}
      sentence={t("message.label", { from: "\u0000", to: author })}
      name={from}
      preview={messagePreview(message.text)}
      label={t("message.label", { from, to: author })}
      open={open}
      onToggle={() => setOpen((value) => !value)}
      body={<AgentMessageBody text={message.text} messageAt={at} />}
    />
  );
});
