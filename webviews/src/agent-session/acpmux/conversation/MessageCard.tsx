// A message to another agent (tell-coordinator, cmux send, a mailbox write, SendMessage) as a
// card: sender to recipient and how it went, the message's first line, and the whole message
// once opened.
import { useId, useLayoutEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AgentMessage } from "./agentMessages";
import { ArrowRight, ChevronDown, ChevronRight, Envelope, Spinner } from "./icons";
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
  // What the send printed (a delivery receipt, or why it failed), under the opened message.
  const output = tool.output?.replace(/\n$/, "");
  return (
    <div className={`cv-message${failed ? " is-failed" : ""}`}>
      <button
        type="button"
        className="cv-message__head"
        aria-expanded={open}
        // The route reads as a sentence (the arrow is a glyph a screen reader skips); the message
        // itself is the text below, outside the button, so it stays selectable.
        aria-label={[t("message.label", { from, to }), failed ? t("tools.failed") : ""].filter(Boolean).join(". ")}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-message__route">
          <span className="cv-tool__icon">{isRunning(tool) ? <Spinner size={16} /> : <Envelope />}</span>
          <span className="cv-message__party">{from}</span>
          <ArrowRight size={12} className="cv-message__arrow" />
          <span className="cv-message__party is-to">{to}</span>
          <span className="cv-message__via">{t(`message.channel.${message.channel}`)}</span>
          {failed && <span className="cv-tool__failed">{t("tools.failed")}</span>}
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
      {open && output && <pre className="cv-tool-output">{output}</pre>}
    </div>
  );
}
