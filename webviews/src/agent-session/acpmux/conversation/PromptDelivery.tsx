// A sent prompt's way to the agent (plans/cmux-next/composer-delivery-DESIGN.md). While it waits,
// from its first second on its way until acpmux took it (or, queued, until the agent reads it), one look: the
// queued row's copy, X and Send now (PendingSteer.tsx; Leo, 2026-11-24: "this one is good. why were
// ther e2 of them"), never a separate "(clock) Sending" in its footer; a send that lands within a
// second shows nothing. A prompt that did not get there for a reason that passes (no answer in
// time, the link down, a busy agent) is still waiting: the same row, and it goes again by itself
// (sendFailure.ts `sendRetriesItself`, direct.ts `resendItself`), with no Not sent, Retry, Edit,
// Remove or Details (Leo, 2026-11-24: "these 4 buttons are really bad tho. i dont ever want to see
// these, it should just fix itself automtically"). Only a refusal that would come back the same
// says why, in one short line under its prompts.
import { Button } from "../../../ui/Button";
import { Tooltip } from "../../../ui/Tooltip";
import { useContext, useEffect, useState } from "react";
import { PROMPT_PENDING_AFTER_MS, type AcpmuxRow, type PromptDelivery } from "../model";
import { useT, type StringKey } from "../i18n";
import { isTrustCause, sendCause, sendRetriesItself } from "../sendFailure";
import { useTranscriptReadOnly } from "./readOnly";
import { FailedSendsContext } from "./promptDeliveryModel";
import { Clock, Close } from "./icons";
import { ROW_ICON } from "./messageActionsModel";
const PENDING_AFTER_MS = PROMPT_PENDING_AFTER_MS;

/// A prompt that did not get there and goes again by itself: shown as on its way, never as failed.
export const resendsItself = (delivery: PromptDelivery | undefined): boolean =>
  delivery?.state === "failed" && sendRetriesItself(delivery);

/// Whether `delivery` draws its pending row now: on its way past its first second, held for the host
/// or not, so a send that lands within a second shows nothing (Leo, 2026-11-24: "this "sending" is
/// bad"), or going again by itself. Re-renders once when the second passes. `queued`: a steer acpmux
/// holds for the running turn draws that row on its own terms (PendingSteer.tsx).
export function usePendingShown(delivery: PromptDelivery | undefined, queued = false): boolean {
  const sending = delivery?.state === "sending";
  const sentAt = delivery?.sentAt ?? 0;
  const [late, setLate] = useState(() => Date.now() - sentAt >= PENDING_AFTER_MS);
  useEffect(() => {
    if (!sending || late) return;
    const timer = setTimeout(() => setLate(true), Math.max(0, PENDING_AFTER_MS - (Date.now() - sentAt)));
    return () => clearTimeout(timer);
  }, [sending, late, sentAt]);
  // Once it went again by itself, its next try keeps the row from its first frame: no footer
  // flashing between tries.
  const again = resendsItself(delivery);
  useEffect(() => {
    if (again && !late) setLate(true);
  }, [again, late]);
  if (again) return true;
  return sending && late && !queued;
}

/// What a prompt still on its way says: the one sentence its footer shows.
export function pendingLabel(delivery: PromptDelivery): StringKey {
  return delivery.waitingForHost ? "prompt.delivery.whenReady" : "prompt.delivery.sending";
}

/// The footer's time slot while the prompt is on its way: a clock and its one sentence, in the
/// slot the age takes once it lands, so the row moves nothing when it does.
export function PendingDelivery({ delivery }: { delivery: PromptDelivery }) {
  const t = useT();
  const label = t(pendingLabel(delivery));
  return (
    <output className="cv-user__time cv-user__pending-state" data-delivery={delivery.state} aria-label={label}>
      <Clock size={12} />
      <span className="cv-user__pending-words">{label}</span>
    </output>
  );
}

/// Under the last prompt of a run acpmux refused for one cause that would refuse it again (too
/// large, the folder's trust question, any other refusal): why, in one short line, and Trust folder
/// where that fixes it, and the pending row's X, which takes the run back into the composer to change
/// (acpmux's table: a failed prompt is edited in place or removed; Retry is the message menu's where
/// it helps). A send that goes again by itself draws nothing here. The run's other prompts draw no
/// line of their own.
export function DeliveryFailure({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const sends = useContext(FailedSendsContext);
  const readOnly = useTranscriptReadOnly();
  const delivery = row.delivery;
  if (!row.failed || readOnly || resendsItself(delivery)) return null;
  const rowIds = sends?.runs.get(row.id)?.rowIds ?? [row.id];
  if (rowIds[rowIds.length - 1] !== row.id) return null;
  const cause = sendCause(delivery);
  const fix = isTrustCause(cause) ? sends?.trustFolder : undefined;
  const takeBack = () => void window.cmuxAcpmuxActions?.["chat.editFailedPrompt"]?.({ rowId: row.id, rowIds });
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
        <Tooltip label={t("composer.queueEditMessage")}>
          <Button
            bare
            className="cv-user__take-back cv-iconbtn cv-iconbtn--compact"
            aria-label={t("composer.queueEditMessage")}
            onClick={takeBack}
          >
            <Close size={ROW_ICON} />
          </Button>
        </Tooltip>
      </div>
    </div>
  );
}
