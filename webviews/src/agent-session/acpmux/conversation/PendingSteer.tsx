import { useContext, useLayoutEffect, useState, useSyncExternalStore, type ReactNode } from "react";

import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit } from "../model";
import { Close } from "./icons";
import { MessageCopy, MessageFooterRow } from "./MessageActions";
import { ROW_ICON } from "./messageActionsModel";
import { TurnActionsContext, type QueuedActions, type TakeBack } from "./turnActions";
import { NewestSteerContext, sentNowState, sentNowListeners, publishSentNow, markSentNow } from "./pendingSteerModel";
export function PendingSteer({
  row,
  send,
  queued,
  children,
}: {
  row: AcpmuxRow;
  send: (promptId: string, edit: QueueEdit) => Promise<boolean>;
  queued?: QueuedActions;
  children?: ReactNode;
}) {
  const t = useT();
  const { unsteer } = useContext(TurnActionsContext);
  const newest = useContext(NewestSteerContext);
  const [sending, setSending] = useState(false);
  const waiting = row.steer === "waiting";
  const [sentNow, setSentNow] = useState(false);
  const [kept, setKept] = useState(false);
  const promptId = row.steerPromptId;
  const sent = useSyncExternalStore(subscribeSentNow, readSentNow, readSentNow);
  // Sent now from any of its controls: this row's Send now, or the composer queue's or a queued
  // card's, which turn a queued prompt into a steer under the same promptId.
  const ownSent = sentNow || Boolean(promptId && sent.ids.has(promptId));
  // The newest steer's Send now covers the earlier ones: the agent reads them with it. Before paint,
  // so an earlier steer never shows its X for a frame after the newest's Send now worked.
  const isNewest = newest === row.id;
  useLayoutEffect(() => {
    if (waiting && ownSent && isNewest) coverUntil(row.at);
  }, [waiting, ownSent, isNewest, row.at]);
  const covered = newest !== undefined && !isNewest && row.at <= sent.coveredAt;
  // The transcript virtualizes rows: a remount must not offer an accepted send again.
  if (!waiting || ownSent || covered) return children ?? null;
  if (!promptId) return null;
  const busy = sending;
  const offersSendNow = newest === undefined || newest === row.id;
  return (
    <div className="cv-user__pending">
      <MessageFooterRow>
        {/* Copy, Retry, Fork and the X show on hover, in the sent row's order; Send now stays
            (Leo, 2026-11-03: "the copy is always showing for no reason... plus the order is wrong"). */}
        <span className="cv-user__queued-hover">
          {row.text?.trim() && <MessageCopy text={row.text} />}
          {queued?.retry}
          {queued?.fork}
          {promptId && unsteer && (
            <button
              type="button"
              className="cv-user__take-back cv-iconbtn cv-iconbtn--compact"
              aria-label={t("composer.queueEditMessage")}
              title={t("composer.queueEditMessage")}
              disabled={busy}
              onClick={() => {
                setSending(true);
                void unsteer(row)
                  .catch((): TakeBack => "failed")
                  .then((result) => setKept(result === "refused"))
                  .finally(() => setSending(false));
              }}
            >
              <Close size={ROW_ICON} />
            </button>
          )}
        </span>
        {kept && <span className="cv-user__kept">{t("message.readAfterStep")}</span>}
        {promptId && offersSendNow && (
          <button
            type="button"
            className="cv-user__send-now"
            // tooltip-allow: says Send now stops only the current step, not the turn; shown nowhere else
            title={t("steer.sendNowHelp")}
            disabled={busy}
            onClick={() => {
              setSending(true);
              void send(promptId, { op: "send_now" })
                .catch(() => false)
                .then((sent) => {
                  if (!sent) return;
                  markSentNow(promptId);
                  setSentNow(true);
                })
                .finally(() => setSending(false));
            }}
          >
            {t("steer.sendNow")}
          </button>
        )}
      </MessageFooterRow>
    </div>
  );
}

function subscribeSentNow(listener: () => void): () => void {
  sentNowListeners.add(listener);
  return () => sentNowListeners.delete(listener);
}
const readSentNow = () => sentNowState;
function coverUntil(at: number): void {
  if (at > sentNowState.coveredAt) publishSentNow({ ...sentNowState, coveredAt: at });
}
