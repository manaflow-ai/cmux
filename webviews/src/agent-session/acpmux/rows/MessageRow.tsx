import { memo, useContext, useState } from "react";
import { AuthorChip } from "../multiplayer/Faces";
import { chiefEnvelope } from "../conversation/chiefEnvelope";
import { type AcpmuxRow } from "../model";
import { isVisiblyEmptyMessage } from "../conversation/visibleMessage";
import { SteerWaitingActions, WaitingMessageMenu } from "../conversation/QueuedMessageCard";
import { useT } from "../i18n";
import { RevealedMarkdown } from "../conversation/RevealedMarkdown";
import { MessageFooterRow, PromptActions, ReceivedActions, ReplyActions } from "../conversation/MessageActions";
import { IncomingMessageLine, IncomingNotice } from "../conversation/IncomingMessageCard";
import { TurnActionsContext } from "../conversation/turnActions";
import { useTranscriptReadOnly } from "../conversation/readOnly";
import { UserBubble } from "../conversation/UserBubble";
import { ChiefPromptBubble } from "../conversation/ChiefPromptBubble";
import { ChevronRight } from "../conversation/icons";
import { CopyButton } from "../conversation/CopyButton";
import { AssistantPresentation } from "../conversation/PresentationContext";
import { InboxNoticeCard } from "../conversation/InboxNoticeCard";
import { type InboxMessage } from "../conversation/inboxNotice";
import { PendingSteer } from "../conversation/PendingSteer";
import { DeliveryFailure } from "../conversation/PromptDelivery";
import { SentFromLine } from "../conversation/SentFromLine";
import { ReceivedResult } from "../offer/SuggestedTasks";
import { callNative } from "../callNative";
import { type RowProps } from "./rowProps";
import { editQueued, openOfferChat, openSenderChat, replyToMessage, sendSteerNow } from "./rowActions";

/// Changes a waiting prompt (`_acpmux/queue_edit`); false when it already started.
/// Keeps one footer mounted through waiting, accepted delivery and the authoritative read event.
const steerControls = (row: AcpmuxRow) =>
  row.steer === "waiting" || (row.steer === "landed" && Boolean(row.text?.trim()));

/// A prompt draws as the user typed it, in a bubble at the right; a reply as Markdown.
export const MessageRow = memo(
  function MessageRow({ row, replyActions, githubRepository }: RowProps) {
    const t = useT();
    const readOnly = useTranscriptReadOnly();
    if (isVisiblyEmptyMessage(row)) return null;
    // A started task's result, which acpmux sent as a prompt: one line, never the person's bubble.
    if (row.kind === "user" && row.received) return <ReceivedResult result={row.received} onOpen={openOfferChat} />;
    // Another agent's message as one line at the left (its sender's chip), its text as a card under
    // it cut to eight lines; a task notification as one quiet line (conversation/incomingMessage.ts).
    // Its images show with it, and its action row (age, Retry) at the line's end on hover;
    // a steer's read state does not: the message is the agent's to read.
    if (row.kind === "user" && row.incoming?.kind === "notice") return <IncomingNotice text={row.incoming.text} />;
    if (row.kind === "user" && row.inboxThread)
      return (
        <div className="cv-incoming">
          <InboxNoticeCard
            rowId={row.id}
            messageAt={row.at}
            notice={{
              threads: [
                {
                  threadId: row.inboxThread.threadId,
                  label: row.inboxThread.label ?? "",
                  from: [row.inboxThread.sender],
                  count: row.inboxThread.count,
                  preview: row.inboxThread.preview,
                  ...(row.inboxThread.newest !== undefined ? { newest: row.inboxThread.newest } : {}),
                  blocker: false,
                  promptIds: [...row.inboxThread.promptIds],
                  ...(row.inboxThread.fromSession ? { fromSession: row.inboxThread.fromSession } : {}),
                  ...(row.inboxThread.fromHarness ? { fromHarness: row.inboxThread.fromHarness } : {}),
                  ...(row.inboxThread.unverified ? { unverified: row.inboxThread.unverified } : {}),
                  // acpmux's record of who sent it: the chip asks for that chat by it (a label-only
                  // sender by its whole label), never by the bare name the line shows.
                  ...(row.inboxThread.senderRecord ? { sender: row.inboxThread.senderRecord } : {}),
                },
              ],
            }}
            onOpen={openSenderChat}
            readThread={readInboxThread}
            githubRepository={githubRepository}
            actions={row.inboxQueue ? <InboxQueueActions queue={row.inboxQueue} version={row.version} /> : undefined}
          />
        </div>
      );
    // acpmux's inbox notice: its threads as received lines, never its text for the agent
    // (conversation/InboxNoticeCard.tsx).
    if (row.kind === "user" && row.incoming?.kind === "inbox")
      return (
        <div className="cv-incoming">
          <InboxNoticeCard
            rowId={row.id}
            notice={row.incoming.notice}
            messageAt={row.at}
            onOpen={openSenderChat}
            readThread={readInboxThread}
            githubRepository={githubRepository}
          />
        </div>
      );
    if (row.kind === "user" && row.incoming?.kind === "message")
      return (
        <div className="cv-incoming">
          <IncomingMessageLine
            id={row.id}
            message={row.incoming.message}
            messageAt={row.at}
            images={row.images}
            onOpen={openSenderChat}
            onReply={readOnly ? undefined : replyToMessage}
            actions={
              readOnly ? undefined : (
                <ReceivedActions
                  row={row}
                  more={
                    row.steer === "waiting" && <SteerWaitingActions promptId={row.steerPromptId} send={sendSteerNow} />
                  }
                />
              )
            }
            githubRepository={githubRepository}
          />
          {row.sentFrom && <SentFromLine from={row.sentFrom} />}
        </div>
      );
    if (row.kind === "user" && row.incoming?.kind === "hidden") return null;
    if (row.kind === "user") {
      // A Chief subagent's first message: the Chief's view as one collapsed line, the task as
      // the message (the session keeps the whole text).
      const envelope = chiefEnvelope(row.text);
      return (
        <div className="cv-user">
          {envelope && (
            // The view's Copy sits outside the disclosure, over the space the summary keeps free at
            // its trailing end, so it never covers the label; a long label ends in an ellipsis.
            <div className="cv-user__context">
              <details>
                <summary>
                  <ChevronRight size={12} className="cv-user__context-chevron" />
                  <span className="cv-user__context-label">
                    {t("transcript.chiefContext", { count: envelope.lines })}
                  </span>
                </summary>
                <pre className="cv-user__context-text selectable">{envelope.context}</pre>
              </details>
              <CopyButton
                text={envelope.context}
                label={t("turn.copy")}
                className="cv-iconbtn cv-iconbtn--compact cv-user__context-copy"
              />
            </div>
          )}
          {envelope || row.from === "chief" ? (
            <>
              <ChiefPromptBubble
                text={envelope ? envelope.task : (row.text ?? "")}
                actions={
                  <PromptActions
                    row={row}
                    text={envelope ? envelope.task : (row.text ?? "")}
                    pending={
                      !readOnly && steerControls(row)
                        ? (actions, queued) => (
                            <PendingSteer row={row} send={editQueued} queued={queued}>
                              {actions}
                            </PendingSteer>
                          )
                        : undefined
                    }
                  />
                }
              />
            </>
          ) : (
            // An unread steer shows only queue controls; accepted or read prompts show normal hover actions.
            <>
              {row.author && <AuthorChip author={row.author} />}
              <UserBubble
                row={row}
                text={row.text ?? ""}
                pending={
                  !readOnly && steerControls(row)
                    ? (actions, queued) => (
                        <PendingSteer row={row} send={editQueued} queued={queued}>
                          {actions}
                        </PendingSteer>
                      )
                    : undefined
                }
              />
            </>
          )}
          <DeliveryFailure row={row} />
          {row.sentFrom ? (
            <SentFromLine from={row.sentFrom} host={row.viaCli} />
          ) : (
            row.viaCli && <div className="cv-user__status">{t("transcript.viaCli", { host: row.viaCli })}</div>
          )}
          {row.agentText && (
            <div className="cv-user__status">
              {row.agentText.from
                ? t("transcript.agentTextNote", { name: row.agentText.from })
                : t("transcript.agentTextNoteUnknown")}
            </div>
          )}
          {row.status && (
            <div className="cv-user__status">
              <span>{row.status}</span>
            </div>
          )}
        </div>
      );
    }
    const reply = (
      <RevealedMarkdown
        text={row.text ?? ""}
        streaming={row.streaming === true}
        githubRepository={githubRepository}
        messageAt={row.at}
        artifactIdentity={row.id}
        artifactRevision={row.version}
        // No claim marks (#39244's green or red underline on "tests pass"): Codex draws a reply as
        // written (Lucas, 2026-11-11: "we want to remove this red line thing").
      />
    );
    // A finished reply its turn's footer does not serve keeps its own action row, whatever follows
    // it (model.ts hasReplyActions).
    if (!replyActions) return <AssistantPresentation>{reply}</AssistantPresentation>;
    return (
      <>
        <AssistantPresentation>{reply}</AssistantPresentation>
        <ReplyActions row={row} />
      </>
    );
  },
  (previous, next) =>
    previous.row.id === next.row.id &&
    previous.row.version === next.row.version &&
    previous.replyActions === next.replyActions &&
    previous.githubRepository === next.githubRepository,
);

/// A queued inbox wrapper has one queue target for the whole notice. Keep its Send now beside the
/// first flattened preview row without turning every delivery into a queue row. No Dismiss: taking
/// a notice out of the queue only puts its messages back as new, and the next notice brings them
/// again (acpmux hub/inbox.rs `notice_done`); agents' messages to each other are not the person's
/// to cancel (Leo, 2026-11-03: "we don't really wanna be cancelling agent back and forth messages
/// 99% of the time").
const InboxQueueActions = memo(function InboxQueueActions({
  queue,
  version,
}: {
  queue: NonNullable<AcpmuxRow["inboxQueue"]>;
  version: number;
}) {
  const act = useContext(TurnActionsContext).queuedMessages?.();
  const [sentAt, setSentAt] = useState<number>();
  const fail = () => undefined;
  return (
    <span className="cv-received-actions">
      <MessageFooterRow>
        <WaitingMessageMenu
          sendNow={
            act && !queue.next && sentAt !== version
              ? () => void act.steer(queue.promptId).then((ok) => ok && setSentAt(version), fail)
              : undefined
          }
        />
      </MessageFooterRow>
    </span>
  );
});

const readInboxThread = (threadId: string) => callNative<InboxMessage[]>("chat.inbox.thread", { threadId });
