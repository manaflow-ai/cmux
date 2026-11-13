import { useContext, useLayoutEffect, useState, useSyncExternalStore, type ReactNode } from "react";

import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit, SteerBehind } from "../model";
import { Close } from "./icons";
import { MessageCopy, MessageFooterRow } from "./MessageActions";
import { ROW_ICON } from "./messageActionsModel";
import { TurnActionsContext, type QueuedActions, type TakeBack } from "./turnActions";
import {
  NewestSteerContext,
  SteerChatContext,
  sentNowState,
  sentNowListeners,
  publishSentNow,
  markSentNow,
} from "./pendingSteerModel";
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
        {kept ? (
          <span className="cv-user__kept">{t("message.readAfterStep")}</span>
        ) : (
          <SteerUnread behind={row.steerBehind} />
        )}
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
                  if (sent) markSentNow(promptId);
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

/// At rest under a steer the agent has not read: "Not read yet", and the step it waits behind in the
/// live line's words (turns.ts `withSteerBehind`), so a message held behind a long command or
/// subagents never reads as ignored (Leo, 2026-11-12: "they're not really responding to my messages.
/// I'm not sure if they're reading them at all."). It goes with the row's controls when the agent
/// reads the steer. The step is cut at the row's edge by CSS, never by a count.
function SteerUnread({ behind }: { behind: SteerBehind | undefined }) {
  const t = useT();
  const step =
    behind?.command !== undefined
      ? behind.command
        ? t("tools.runningCommand", { command: behind.command })
        : t("tools.runningUnnamed")
      : behind?.call
        ? behind.call
        : behind?.agents
          ? t("turn.live.waitingOnSubagents", { n: behind.agents })
          : undefined;
  const notRead = t("steer.notReadYet");
  const text = step ? `${notRead} · ${step}` : notRead;
  return (
    // tooltip-allow: the whole step, which the row's edge may cut; shown nowhere else in full
    <output className="cv-user__unread" title={text}>
      {text}
    </output>
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
