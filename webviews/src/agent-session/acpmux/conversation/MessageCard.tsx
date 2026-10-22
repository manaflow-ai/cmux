// A message to another agent (tell-coordinator, cmux send, a mailbox write, SendMessage) as one
// collapsed line, the shared agent message row (AgentMessageRow.tsx) that a received message
// draws too: the envelope, "Sent to <recipient>", the message's first line muted, and the chevron
// (Leo 2026-10-21: "more collapsed from the start", as Claude draws its message rows). Opened, the
// whole message in a glass card, then one status line with its glyph: Sending…, Sent, or Delivered
// to <recipient> from the send's receipt ("delivered to leoli-24 (id 9defc4d0ed87)"), whose id is
// never shown (#20456), and how it went out; then what else the send printed. Whether it is open
// lasts across the virtualized transcript (transcriptDisclosure.tsx), and Find in Chat opens it.
import { useMemo } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AgentMessage } from "./agentMessages";
import { AgentMessageRow, messagePreview } from "./AgentMessageRow";
import { useFindReveal } from "./chatFind";
import { Check, DoubleCheck, Envelope, Spinner } from "./icons";
import { isFailed, isRunning } from "./toolGroups";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

export function MessageCard({ item, message }: { item: AcpmuxActivity; message: AgentMessage }) {
  const t = useT();
  const tool = item.tool!;
  const [open, setOpen] = useTranscriptDisclosure(`message:${tool.id}`);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const from = message.from ?? t("message.self");
  const to = message.to ?? t("message.unknown");
  const failed = isFailed(tool);
  const running = isRunning(tool);
  const output = tool.output?.replace(/\n$/, "");
  const receipt = output && /^delivered to (\S+?)(?: \(id [^)]*\))?\s*$/im.exec(output);
  // What else the send printed: its output without the receipt line, which the status line says.
  const rest =
    receipt && !failed
      ? (output.slice(0, receipt.index) + output.slice(receipt.index + receipt[0].length)).trim()
      : output;
  const delivery = failed ? "failed" : running ? "sending" : receipt ? "delivered" : "sent";
  const status =
    delivery === "failed"
      ? t("tools.failed")
      : delivery === "sending"
        ? t("message.sending")
        : delivery === "delivered"
          ? t("message.delivered", { to: receipt![1]! })
          : t("message.sent");
  const glyph =
    delivery === "sending" ? (
      <Spinner size={12} />
    ) : delivery === "delivered" ? (
      <DoubleCheck size={12} />
    ) : delivery === "sent" ? (
      <Check size={12} />
    ) : null;
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
      label={[t("message.label", { from, to }), failed ? t("tools.failed") : ""].filter(Boolean).join(". ")}
      open={open}
      onToggle={() => setOpen((value) => !value)}
      failed={failed}
      live={running}
      meta={
        failed ? (
          <span className="cv-command__meta cv-agentmsg__status">{t("tools.failed")}</span>
        ) : delivery === "sending" ? undefined : (
          <span className="cv-command__meta">
            {delivery === "delivered" ? (
              <DoubleCheck size={14} className="cv-command__ok" />
            ) : (
              <Check size={14} className="cv-command__ok" />
            )}
          </span>
        )
      }
      body={message.text || t("message.noText")}
      under={
        <>
          <div className="cv-agentmsg__under cv-message__receipt">
            {glyph}
            <span className="cv-agentmsg__status cv-message__status">{status}</span>
            <span aria-hidden>·</span>
            <span className="cv-message__via">{t(`message.channel.${message.channel}`)}</span>
          </div>
          {/* What else the send printed (a tool's own reply), and all of it when the send failed. */}
          {rest && <pre className="cv-tool-output cv-agentmsg__output selectable">{rest}</pre>}
        </>
      }
    />
  );
}
