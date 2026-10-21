// A sent prompt's way to the agent (plans/cmux-next/composer-delivery-DESIGN.md): a clock beside its
// bubble while it is on its way (only after a second, so a fast send shows nothing); once it got
// there the bubble's read check (UserBubble.tsx) says so. A prompt that did not get there says why, with
// Retry, Edit, Remove and Details: the hop it stopped at, its error, each hop's time and the ids,
// and Copy debug info.
import { useEffect, useState } from "react";
import type { AcpmuxRow, PromptDelivery } from "../model";
import { useT, type StringKey } from "../i18n";
import { copyText } from "./clipboard";
import { Clock } from "./icons";

/// How long a send stays unmarked before its clock shows.
const CLOCK_AFTER_MS = 1000;

const HOP_LABEL = {
  connection: "prompt.delivery.hop.connection",
  acpmux: "prompt.delivery.hop.acpmux",
  agent: "prompt.delivery.hop.agent",
} as const satisfies Record<NonNullable<PromptDelivery["hop"]>, StringKey>;

/// The clock beside a prompt that is still on its way.
export function DeliveryMark({ delivery }: { delivery: PromptDelivery }) {
  const t = useT();
  const sending = delivery.state === "sending";
  const [late, setLate] = useState(() => Date.now() - delivery.sentAt >= CLOCK_AFTER_MS);
  useEffect(() => {
    if (!sending || late) return;
    const timer = setTimeout(() => setLate(true), Math.max(0, CLOCK_AFTER_MS - (Date.now() - delivery.sentAt)));
    return () => clearTimeout(timer);
  }, [sending, late, delivery.sentAt]);
  if (!sending || (!late && !delivery.slow)) return null;
  const label = t(delivery.slow ? "prompt.delivery.stillSending" : "prompt.delivery.sending");
  // The clock alone names itself in a tooltip; once the send is slow its words show, and no tooltip.
  if (!delivery.slow)
    return (
      <output
        className="cv-user__status cv-user__delivery"
        data-delivery={delivery.state}
        aria-label={label}
        title={label}
      >
        <Clock size={12} />
      </output>
    );
  return (
    <output className="cv-user__status cv-user__delivery" data-delivery={delivery.state} aria-label={label}>
      <Clock size={12} />
      <span>{label}</span>
    </output>
  );
}

/// The debug text Copy debug info puts on the clipboard: plain lines, for a bug report.
export function deliveryDebugText(row: Pick<AcpmuxRow, "id" | "text">, delivery: PromptDelivery): string {
  const at = (ms: number | undefined) => (ms === undefined ? "-" : new Date(ms).toISOString());
  const after = (ms: number | undefined) => (ms === undefined ? "-" : `${ms - delivery.sentAt} ms`);
  return [
    `state: ${delivery.state}`,
    `hop: ${delivery.hop ?? "-"}`,
    `code: ${delivery.code ?? "-"}`,
    `error: ${delivery.error ?? "-"}`,
    `sent: ${at(delivery.sentAt)}`,
    `accepted: ${at(delivery.acceptedAt)} (${after(delivery.acceptedAt)})`,
    `read: ${at(delivery.readAt)} (${after(delivery.readAt)})`,
    `failed: ${at(delivery.failedAt)} (${after(delivery.failedAt)})`,
    `session: ${delivery.sessionId}`,
    `prompt: ${delivery.promptId}`,
    `row: ${row.id}`,
    `connection: ${delivery.connection ?? "local"}`,
    `characters: ${row.text?.length ?? 0}`,
  ].join("\n");
}

/// Under a prompt that did not get there: why, and how to recover it.
export function DeliveryFailure({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const delivery = row.delivery;
  if (!row.failed) return null;
  const act = (name: string) => void window.cmuxAcpmuxActions?.[name]?.({ rowId: row.id });
  const since = (ms: number | undefined) =>
    ms === undefined ? undefined : t("prompt.delivery.after", { ms: Math.max(0, ms - (delivery?.sentAt ?? ms)) });
  return (
    <div className="cv-user__status cv-user__status--failed" aria-live="polite">
      <div className="cv-user__failure">
        <span>{row.error ?? t("prompt.notSent", { reason: t("transport.refused") })}</span>
        <button type="button" className="cv-user__cancel" onClick={() => act("chat.retryPrompt")}>
          {t("turn.retry")}
        </button>
        {delivery && (
          <>
            <button type="button" className="cv-user__cancel" onClick={() => act("chat.editFailedPrompt")}>
              {t("message.edit")}
            </button>
            <button type="button" className="cv-user__cancel" onClick={() => act("chat.removeFailedPrompt")}>
              {t("prompt.delivery.remove")}
            </button>
            <button
              type="button"
              className="cv-user__cancel"
              aria-expanded={open}
              onClick={() => setOpen((shown) => !shown)}
            >
              {t("prompt.delivery.details")}
            </button>
          </>
        )}
      </div>
      {open && delivery && (
        <div className="cv-user__delivery-details selectable">
          {delivery.hop && <div>{t(HOP_LABEL[delivery.hop])}</div>}
          {delivery.error && (
            <div>
              {delivery.error}
              {delivery.code ? ` (${delivery.code})` : ""}
            </div>
          )}
          <div>
            {t("prompt.delivery.sentLabel")}: {new Date(delivery.sentAt).toLocaleTimeString()}
          </div>
          {delivery.acceptedAt !== undefined && (
            <div>
              {t("prompt.delivery.acceptedLabel")}: {since(delivery.acceptedAt)}
            </div>
          )}
          {delivery.failedAt !== undefined && (
            <div>
              {t("prompt.delivery.failedLabel")}: {since(delivery.failedAt)}
            </div>
          )}
          <div>{delivery.promptId}</div>
          <button
            type="button"
            className="cv-user__cancel"
            onClick={() =>
              void copyText(deliveryDebugText(row, delivery)).then(
                () => setCopied(true),
                () => setCopied(false),
              )
            }
          >
            {copied ? t("turn.copied") : t("prompt.delivery.copyDebug")}
          </button>
        </div>
      )}
    </div>
  );
}
