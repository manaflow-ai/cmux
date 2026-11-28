import { useContext, useLayoutEffect, useState, useSyncExternalStore, type ReactNode } from "react";

import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit } from "../model";
import { Close } from "./icons";
import { MessageCopy, MessageFooterRow } from "./MessageActions";
import { ROW_ICON } from "./messageActionsModel";
import { TurnActionsContext, type QueuedActions, type TakeBack } from "./turnActions";
import { resendsItself, usePendingShown } from "./PromptDelivery";
import {
  NewestSteerContext,
  SteerChatContext,
  sentNowState,
  sentNowListeners,
  publishSentNow,
  markSentNow,
} from "./pendingSteerModel";
/// A prompt's one pending look, from the moment it is on its way until acpmux took it and the agent
/// read it: copy, Retry, Fork and the X on hover, and Send now, as a steer queued behind the
/// running turn has drawn them since #22834 (Leo, 2026-11-24: "why is THIS one find and good? ...
/// this one is good. why were ther e2 of them"). Before, a prompt acpmux had not answered yet said
/// "(clock) Sending" in its footer instead (#41513), a second look for the same waiting message.
/// Now one row serves three states:
/// - queued (acpmux holds it for the running turn's step, `row.steer === "waiting"`): X takes it
///   back into the composer and Send now sends it into the step now, as before;
/// - on its way (sent, not answered yet, past its first second, so a fast send shows nothing): it
///   cannot be stopped or hurried, so X and Send now are drawn disabled, the row the same size;
/// - going again by itself (it did not get there for a reason that passes: no answer in time, the
///   link down; sendFailure.ts `sendRetriesItself`): Send now tries again at once, and X takes it
///   back into the composer, as a queued prompt's X does.
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
  const chat = useContext(SteerChatContext);
  const [sending, setSending] = useState(false);
  const waiting = row.steer === "waiting";
  const [kept, setKept] = useState(false);
  const promptId = row.steerPromptId;
  const sent = useSyncExternalStore(subscribeSentNow, readSentNow, readSentNow);
  // On its way or going again by itself, past its first second (PromptDelivery.tsx). A steer or a
  // prompt queued behind the turn has its own terms (queued above, or gone once sent now: Leo,
  // 2026-10-24: "after i clicked send now and it worked it should just disappear").
  const onItsWay = usePendingShown(row.delivery, row.steer !== undefined || row.delivery?.queued === true);
  const retrying = row.failed === true && resendsItself(row.delivery);
  // Sent now from any of its controls: this row's Send now, or the composer queue's or a queued
  // card's, which turn a queued prompt into a steer under the same promptId. Read from the store by
  // promptId, never this row's own state: row ids repeat across chats, so React keeps this row when
  // the page switches chats in place (cmux#32846).
  const ownSent = Boolean(promptId && sent.ids.has(promptId));
  // The newest steer's Send now covers the earlier ones: the agent reads them with it. Before paint,
  // so an earlier steer never shows its X for a frame after the newest's Send now worked.
  const isNewest = newest === row.id;
  useLayoutEffect(() => {
    if (waiting && ownSent && isNewest) coverUntil(chat, row.at);
  }, [waiting, ownSent, isNewest, chat, row.at]);
  const covered = newest !== undefined && !isNewest && row.at <= (sent.coveredAt.get(chat) ?? Number.NEGATIVE_INFINITY);
  // The transcript virtualizes rows: a remount must not offer an accepted send again.
  const queuedNow = waiting && !ownSent && !covered;
  if (!queuedNow && !onItsWay) return children ?? null;
  if (queuedNow && !promptId) return null;
  const busy = sending;
  const offersSendNow = !queuedNow || newest === undefined || newest === row.id;
  const act = (name: string) => window.cmuxAcpmuxActions?.[name]?.({ rowId: row.id, rowIds: [row.id] });
  // What X and Send now do in the row's state; undefined: drawn, disabled (nothing to do yet).
  const takeBack = queuedNow
    ? promptId && unsteer
      ? () => unsteer(row).catch((): TakeBack => "failed")
      : undefined
    : retrying
      ? () => Promise.resolve(act("chat.editFailedPrompt")).then((): TakeBack => "back")
      : undefined;
  const sendNow = queuedNow
    ? promptId
      ? () => send(promptId, { op: "send_now" }).catch(() => false)
      : undefined
    : retrying
      ? () =>
          Promise.resolve(act("chat.retryPrompt"))
            .then(() => false)
            .catch(() => false)
      : undefined;
  return (
    <div className="cv-user__pending">
      <MessageFooterRow>
        {/* Copy, Retry, Fork and the X show on hover, in the sent row's order; Send now stays
            (Leo, 2026-11-03: "the copy is always showing for no reason... plus the order is wrong").
            No Save as Prompt here or in any footer (Leo, 2026-11-24: "save prompt butotn still bad"). */}
        <span className="cv-user__queued-hover">
          {row.text?.trim() && <MessageCopy text={row.text} />}
          {queued?.retry}
          {queued?.fork}
          {(!queuedNow || (promptId && unsteer)) && (
            <button
              type="button"
              className="cv-user__take-back cv-iconbtn cv-iconbtn--compact"
              aria-label={t("composer.queueEditMessage")}
              title={t("composer.queueEditMessage")}
              disabled={busy || !takeBack}
              onClick={() => {
                if (!takeBack) return;
                setSending(true);
                void takeBack()
                  .then((result) => setKept(result === "refused"))
                  .finally(() => setSending(false));
              }}
            >
              <Close size={ROW_ICON} />
            </button>
          )}
        </span>
        {kept && (
          <span
            className="cv-user__kept"
            // tooltip-allow: in a narrow pane the note is cut to the row so Send now stays clear of it
            title={t("message.readAfterStep")}
          >
            {t("message.readAfterStep")}
          </span>
        )}
        {offersSendNow && (
          <button
            type="button"
            className="cv-user__send-now"
            // tooltip-allow: says Send now stops only the current step, not the turn; shown nowhere else
            title={t("steer.sendNowHelp")}
            disabled={busy || !sendNow}
            data-pending-state={queuedNow ? "queued" : retrying ? "retrying" : "sending"}
            onClick={() => {
              if (!sendNow) return;
              setSending(true);
              void sendNow()
                .then((sent) => {
                  if (sent && promptId) markSentNow(promptId);
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
function coverUntil(chat: string, at: number): void {
  if (at > (sentNowState.coveredAt.get(chat) ?? Number.NEGATIVE_INFINITY))
    publishSentNow({ ...sentNowState, coveredAt: new Map(sentNowState.coveredAt).set(chat, at) });
}
