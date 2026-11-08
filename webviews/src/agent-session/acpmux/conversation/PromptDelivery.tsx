// A sent prompt's way to the agent (plans/cmux-next/composer-delivery-DESIGN.md): a clock beside its
// bubble while it is on its way (only after a second, so a fast send shows nothing); once it got
// there the bubble's read check (UserBubble.tsx) says so. Prompts that did not get there say why in
// one card per cause (sendFailure.ts), under the last of them: one plain sentence, the fix when
// there is one (Trust folder), Retry, Edit, Remove and Details: the hop it stopped at, the
// refuser's own words and code, each hop's time and the ids, and Copy debug info.
import { useContext, useEffect, useState } from "react";
import type { AcpmuxRow, PromptDelivery } from "../model";
import { useT, type StringKey } from "../i18n";
import { isTrustCause, retryHelps, sendCause } from "../sendFailure";
import { copyText } from "./clipboard";
import { Clock } from "./icons";
import { useTranscriptReadOnly } from "./readOnly";
import { FailedSendsContext, deliveryDebugText } from "./promptDeliveryModel";
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

/// Under the last prompt of a run that did not get there for one cause: why, and how to recover
/// them. The run's other prompts draw no card of their own.
export function DeliveryFailure({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const sends = useContext(FailedSendsContext);
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const readOnly = useTranscriptReadOnly();
  const delivery = row.delivery;
  if (!row.failed || readOnly) return null;
  const rowIds = sends?.runs.get(row.id)?.rowIds ?? [row.id];
  if (rowIds[rowIds.length - 1] !== row.id) return null;
  const cause = sendCause(delivery);
  const trust = isTrustCause(cause);
  const retryWaits = trust ? sends?.trustBlock : undefined;
  const fix = trust ? sends?.trustFolder : undefined;
  const act = (name: string) => void window.cmuxAcpmuxActions?.[name]?.({ rowId: row.id, rowIds });
  const codes = [...new Set([delivery?.reason, delivery?.code].filter(Boolean))];
  const since = (ms: number | undefined) =>
    ms === undefined ? undefined : t("prompt.delivery.after", { ms: Math.max(0, ms - (delivery?.sentAt ?? ms)) });
  return (
    <div
      className="cv-user__status cv-user__status--failed"
      data-failure-cause={cause}
      data-failed-count={rowIds.length}
      aria-live="polite"
    >
      <div className="cv-user__failure-text">
        {row.error ?? t("prompt.notSent", { reason: t("transport.refused") })}
      </div>
      <div className="cv-user__failure">
        {fix && (
          <button type="button" className="cv-user__cancel cv-user__fix" onClick={fix}>
            {t("trust.trustFolder")}
          </button>
        )}
        {/* A prompt too large to send is refused the same way again: Edit takes an attachment out. */}
        {retryHelps(cause) && (
          <button
            type="button"
            className="cv-user__cancel"
            disabled={retryWaits !== undefined}
            title={retryWaits && t(retryWaits)}
            onClick={() => act("chat.retryPrompt")}
          >
            {t("turn.retry")}
          </button>
        )}
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
              {codes.length ? ` (${codes.join(", ")})` : ""}
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
