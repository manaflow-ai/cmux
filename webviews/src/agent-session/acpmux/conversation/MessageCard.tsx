// A message to another agent (tell-coordinator, cmux send, a mailbox write, SendMessage) as one
// collapsed line, the shared agent message row (AgentMessageRow.tsx) that a received message
// draws too: the envelope, "Sent to <recipient>", the message's first line muted, the chevron,
// and how far it got as one muted word at the line's end (Sent, Queued, Delivered, Failed;
// agentMessages.ts `messageDelivery`). The recipient is a name, never an id (agentNames.ts). Copy
// is in the line's hover row. Opened, the message grows in place: its whole text under the line,
// with no box around it, capped near eight lines and scrolling past them under a fade, and
// nothing else (Leo 2026-10-21: the result's JSON under it was "immediately TMI"). Whether it is open lasts across
// the virtualized transcript (transcriptDisclosure.tsx), and Find in Chat opens it.
import { useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { messageDelivery, type AgentMessage, type Delivery } from "./agentMessages";
import { AgentMessageRow, messagePreview } from "./AgentMessageRow";
import { AgentNamesContext, recipientName } from "./agentNames";
import { useFindReveal } from "./chatFind";
import { Envelope, Spinner } from "./icons";
import { SentActions } from "./MessageActions";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

export function MessageCard({ item, message }: { item: AcpmuxActivity; message: AgentMessage }) {
  const t = useT();
  const tool = item.tool!;
  const names = useContext(AgentNamesContext);
  const [open, setOpen] = useTranscriptDisclosure(`message:${tool.id}`);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const from = message.from ?? t("message.self");
  const to = message.to ? (recipientName(message.to, names) ?? t("message.agent")) : t("message.unknown");
  const delivery = messageDelivery(tool);
  const running = delivery === "sending";
  const failed = delivery === "failed";
  const status = deliveryWord(t, delivery);
  return (
    <AgentMessageRow
      direction="sent"
      className="cv-message"
      attributes={{ "data-delivery": delivery }}
      icon={running ? <Spinner size={16} /> : <Envelope />}
      sentence={t(running ? "message.sendingTo" : "message.sentTo", { to: "\u0000" })}
      name={to}
      preview={messagePreview(message.text) || t("message.noText")}
      // The route reads as a sentence; the message itself is in the card, outside the button, so
      // it stays selectable.
      label={[t("message.label", { from, to }), status].filter(Boolean).join(". ")}
      open={open}
      onToggle={() => setOpen((value) => !value)}
      failed={failed}
      live={running}
      meta={
        status ? <span className="cv-command__meta cv-agentmsg__status cv-message__status">{status}</span> : undefined
      }
      actions={message.text ? <SentActions text={message.text} /> : undefined}
      body={<MessageText text={message.text || t("message.noText")} />}
    />
  );
}

/// The one muted word a send's line ends with; none while it goes out (the line reads "Sending to").
function deliveryWord(t: ReturnType<typeof useT>, delivery: Delivery): string | undefined {
  switch (delivery) {
    case "sending":
      return undefined;
    case "sent":
      return t("message.sent");
    case "queued":
      return t("message.queued");
    case "delivered":
      return t("message.deliveredShort");
    case "failed":
      return t("message.failed");
  }
}

/// The opened message: its text, capped near eight lines, scrolling past them under a fade that
/// lifts at the end.
function MessageText({ text }: { text: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const [more, setMore] = useState(false);
  const measure = () => {
    const node = ref.current;
    if (node) setMore(node.scrollHeight - node.scrollTop - node.clientHeight > 1);
  };
  useLayoutEffect(measure, [text]);
  return (
    <div ref={ref} className={`cv-message__text${more ? " has-more" : ""}`} onScroll={measure}>
      {text}
    </div>
  );
}
