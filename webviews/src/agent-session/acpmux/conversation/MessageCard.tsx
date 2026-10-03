// A message to another agent (tell-coordinator, cmux send, a mailbox write, SendMessage) as a
// card: sender to recipient and how it went, the message's first line, and the whole message
// once opened.
import { useState } from "react";
import { t } from "../i18n";
import type { AcpmuxActivity } from "../model";
import type { AgentMessage } from "./agentMessages";
import { ArrowRight, ChevronRight, Envelope, Spinner } from "./icons";
import { isFailed, isRunning } from "./toolGroups";

export function MessageCard({ item, message }: { item: AcpmuxActivity; message: AgentMessage }) {
  const [open, setOpen] = useState(false);
  const tool = item.tool!;
  const from = message.from ?? t("message.self");
  const to = message.to ?? t("message.unknown");
  const preview = message.text.split("\n").find((line) => line.trim()) ?? "";
  const failed = isFailed(tool);
  const output = failed ? tool.output?.replace(/\n$/, "") : undefined;
  return (
    <div className={`cv-message${failed ? " is-failed" : ""}`}>
      <button
        type="button"
        className="cv-message__head"
        aria-expanded={open}
        aria-label={t("message.label", { from, to })}
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
        {!open && <span className="cv-message__preview">{preview || t("message.noText")}</span>}
      </button>
      {open && <div className="cv-message__body">{message.text || t("message.noText")}</div>}
      {open && output && <pre className="cv-tool-output">{output}</pre>}
    </div>
  );
}
