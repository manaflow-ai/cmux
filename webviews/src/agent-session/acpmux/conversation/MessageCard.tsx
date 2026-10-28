// A message to another agent (tell-coordinator, cmux send, a mailbox write, SendMessage) as one
// collapsed line, the shared agent message row (AgentMessageRow.tsx) that a received message
// draws too: the envelope, "Sent to <recipient>", the message's first line muted, the chevron,
// and how far it got as one muted word at the line's end (Sent, Queued, Delivered, Failed;
// agentMessages.ts `messageDelivery`). The recipient is a name: a subagent by its description, or
// a short id when nothing names it, the full id in the chip's tooltip (agentNames.ts). Copy
// is in the line's hover row. Opened, the message grows in place: its whole text under the line,
// with no box around it, cut between whole lines with Show more, and
// nothing else (Leo 2026-10-21: the result's JSON under it was "immediately TMI"). Whether it is open lasts across
// the virtualized transcript (transcriptDisclosure.tsx), and Find in Chat opens it.
import { useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { messageDelivery, notDeliveredReason, type AgentMessage, type Delivery } from "./agentMessages";
import { AgentMessageRow, messagePreview } from "./AgentMessageRow";
import { AgentNamesContext, recipientName, shortId } from "./agentNames";
import { useFindReveal } from "./chatFind";
import { Envelope, Spinner } from "./icons";
import { SentActions } from "./MessageActions";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { Markdown } from "./Markdown";
import { wholeLineCut } from "./lineCut";

export function MessageCard({
  item,
  message,
  messageAt,
}: {
  item: AcpmuxActivity;
  message: AgentMessage;
  messageAt?: number;
}) {
  const t = useT();
  const tool = item.tool!;
  const names = useContext(AgentNamesContext);
  const [open, setOpen] = useTranscriptDisclosure(`message:${tool.id}`);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const from = message.from ?? t("message.self");
  const to = message.to ? (recipientName(message.to, names) ?? shortId(message.to)) : t("message.unknown");
  // The full id under a subagent's name or short id, for matching it against a log.
  const toId = message.to && to !== message.to.trim() ? t("message.recipientId", { id: message.to.trim() }) : undefined;
  const delivery = messageDelivery(tool, message);
  const running = delivery === "sending";
  const failed = delivery === "failed";
  const status = deliveryWord(t, delivery, tool);
  return (
    <AgentMessageRow
      direction="sent"
      className="cv-message"
      attributes={{ "data-delivery": delivery }}
      icon={running ? <Spinner size={16} /> : <Envelope />}
      sentence={t(running ? "message.sendingTo" : "message.sentTo", { to: "\u0000" })}
      name={to}
      nameTitle={toId}
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
      body={<MessageText item={item} text={message.text || t("message.noText")} messageAt={messageAt} />}
    />
  );
}

/// How far a send got, at its line's end: one muted word (Sent, Queued, Delivered), none while it
/// goes out (the line reads "Sending to"), and for a send that did not arrive, why, in the muted
/// warning tone: "Not delivered: agent stopped", "Not delivered: no such agent", "Not delivered".
function deliveryWord(
  t: ReturnType<typeof useT>,
  delivery: Delivery,
  tool: NonNullable<AcpmuxActivity["tool"]>,
): string | undefined {
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
      switch (notDeliveredReason(tool)) {
        case "stopped":
          return t("message.notDeliveredStopped");
        case "noAgent":
          return t("message.notDeliveredNoAgent");
        case "other":
          return t("message.notDelivered");
      }
  }
}

/// The opened message: whole lines, then an explicit disclosure control.
function MessageText({ item, text, messageAt }: { item: AcpmuxActivity; text: string; messageAt?: number }) {
  const t = useT();
  const id = useId();
  const [expanded, setExpanded] = useTranscriptDisclosure(`message-text:${item.tool!.id}`);
  useFindReveal([item], () => setExpanded(true));
  const ref = useRef<HTMLDivElement>(null);
  const [cutAt, setCutAt] = useState<number>();
  const measure = () => {
    const node = ref.current;
    if (!node) return;
    const limit = 8 * parseFloat(node.ownerDocument.defaultView!.getComputedStyle(node).lineHeight);
    setCutAt(node.scrollHeight > limit + 1 ? wholeLineCut(node, limit) : undefined);
  };
  useLayoutEffect(() => {
    measure();
    // The pane's width decides the wrap and therefore the safe cut.
    const node = ref.current;
    if (!node || typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    observer.observe(node.firstElementChild ?? node);
    return () => observer.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- measure reads only the node
  }, [text]);
  const cut = !expanded && cutAt !== undefined;
  return (
    <>
      <div
        id={id}
        ref={ref}
        className={`cv-message__text${cut ? " is-cut" : ""}`}
        style={cut ? { maxHeight: cutAt } : undefined}
        onFocusCapture={cut ? () => setExpanded(true) : undefined}
      >
        <Markdown messageAt={messageAt}>{text}</Markdown>
      </div>
      {cutAt !== undefined && (
        <button
          type="button"
          className="cv-user__more cv-message__more"
          aria-expanded={expanded}
          aria-controls={id}
          data-find-skip=""
          onClick={() => setExpanded(!expanded)}
        >
          {t(expanded ? "message.less" : "message.more")}
        </button>
      )}
    </>
  );
}
