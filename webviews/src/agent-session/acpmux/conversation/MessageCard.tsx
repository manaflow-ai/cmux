// A message to another agent (tell-coordinator, cmux send, a mailbox write, SendMessage) as a
// card: sender to recipient, the message's first lines (the whole message once opened when it is
// long), and one status line with its glyph: Sending…, Sent, or Delivered to <recipient> from the
// send's receipt ("delivered to leoli-24 (id 9defc4d0ed87)"), whose id is never shown (#20456).
import { useId, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AgentMessage } from "./agentMessages";
import { ArrowRight, Check, ChevronDown, ChevronRight, DoubleCheck, Envelope, Spinner } from "./icons";
import { isFailed, isRunning } from "./toolGroups";

export function MessageCard({ item, message }: { item: AcpmuxActivity; message: AgentMessage }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const tool = item.tool!;
  const from = message.from ?? t("message.self");
  const to = message.to ?? t("message.unknown");
  // Two lines show closed; a message that overflows them gets Show more. The first paint guesses
  // (a third line, or ~140 characters); once laid out, the clamped body measures itself, again
  // whenever its width changes. Open, the toggle stays for Show less.
  const [long, setLong] = useState(() => message.text.split("\n").length > 2 || message.text.length > 140);
  const body = useRef<HTMLDivElement>(null);
  const bodyId = useId();
  useLayoutEffect(() => {
    const node = body.current;
    if (!node || open) return;
    const measure = () => setLong(node.scrollHeight > node.clientHeight + 1);
    measure();
    if (typeof ResizeObserver !== "function") return;
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, [open, message.text]);
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
  return (
    <div className={`cv-message${failed ? " is-failed" : ""}`} data-delivery={delivery}>
      <button
        type="button"
        className="cv-message__head"
        aria-expanded={open}
        aria-controls={bodyId}
        // The route reads as a sentence (the arrow is a glyph a screen reader skips); the message
        // itself is the text below, outside the button, so it stays selectable.
        aria-label={[t("message.label", { from, to }), failed ? t("tools.failed") : ""].filter(Boolean).join(". ")}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-message__route">
          <span className="cv-tool__icon">
            <Envelope />
          </span>
          <span className="cv-message__party">{from}</span>
          <ArrowRight size={12} className="cv-message__arrow" />
          <span className="cv-message__party is-to">{to}</span>
          <span className="cv-message__via">{t(`message.channel.${message.channel}`)}</span>
          <ChevronRight
            size={14}
            strokeWidth={1.2}
            className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
          />
        </span>
      </button>
      <div ref={body} id={bodyId} className={`cv-message__body${open ? "" : " is-clamped"}`}>
        {message.text || t("message.noText")}
      </div>
      {long && (
        <button
          type="button"
          className="cv-message__more"
          aria-expanded={open}
          aria-controls={bodyId}
          onClick={() => setOpen((value) => !value)}
        >
          {t(open ? "message.less" : "message.more")}
          <ChevronDown size={12} className={`cv-rotor${open ? " is-flipped" : ""}`} />
        </button>
      )}
      <div className="cv-message__receipt">
        {delivery === "sending" ? (
          <Spinner size={12} />
        ) : delivery === "delivered" ? (
          <DoubleCheck size={12} />
        ) : delivery === "sent" ? (
          <Check size={12} />
        ) : null}
        <span className="cv-message__status">{status}</span>
      </div>
      {/* What else the send printed (a tool's own reply), and all of it when the send failed. */}
      {open && rest && <pre className="cv-tool-output">{rest}</pre>}
    </div>
  );
}
