// The `user` and `assistant` rows: a prompt as the person typed it, a reply as Markdown.
import { memo } from "react";
import { ChiefPromptBubble } from "../conversation/ChiefPromptBubble";
import { CopyButton } from "../conversation/CopyButton";
import { IncomingMessageLine, IncomingNotice } from "../conversation/IncomingMessageCard";
import { PromptActions, ReceivedActions } from "../conversation/MessageActions";
import { PendingSteer } from "../conversation/PendingSteer";
import { DeliveryFailure } from "../conversation/PromptDelivery";
import { SteerWaitingActions } from "../conversation/QueuedMessageCard";
import { RevealedMarkdown } from "../conversation/RevealedMarkdown";
import { UserBubble } from "../conversation/UserBubble";
import { chiefEnvelope } from "../conversation/chiefEnvelope";
import { ChevronRight } from "../conversation/icons";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { AuthorChip } from "../multiplayer/Faces";
import { ReceivedResult } from "../offer/SuggestedTasks";
import { editQueued, openOfferChat, openSenderChat, replyToMessage, sendSteerNow } from "./rowActions";
import type { RowProps } from "./rowProps";

/// Keeps one footer mounted through waiting, accepted delivery and the authoritative read event.
const steerControls = (row: AcpmuxRow) =>
  row.steer === "waiting" || (row.steer === "landed" && Boolean(row.text?.trim()));

/// A prompt draws as the user typed it, in a bubble at the right; a reply as Markdown.
export const MessageRow = memo(
  function MessageRow({ row, githubRepository }: RowProps) {
    const t = useT();
    // A started task's result, which acpmux sent as a prompt: one line, never the person's bubble.
    if (row.kind === "user" && row.received) return <ReceivedResult result={row.received} onOpen={openOfferChat} />;
    // Another agent's message as one line at the left (its sender's chip), its text as a card under
    // it cut to eight lines; a task notification as one quiet line (conversation/incomingMessage.ts).
    // Its images show with it, and its action row (age, Copy, Retry, Pin) at the line's end on hover;
    // a steer's read state does not: the message is the agent's to read.
    if (row.kind === "user" && row.incoming?.kind === "notice") return <IncomingNotice text={row.incoming.text} />;
    if (row.kind === "user" && row.incoming?.kind === "message")
      return (
        <div className="cv-incoming">
          <IncomingMessageLine
            id={row.id}
            message={row.incoming.message}
            messageAt={row.at}
            images={row.images}
            onOpen={openSenderChat}
            onReply={replyToMessage}
            actions={
              <>
                <ReceivedActions row={row} text={row.incoming.message.text} />
                {row.steer === "waiting" && <SteerWaitingActions promptId={row.steerPromptId} send={sendSteerNow} />}
              </>
            }
            githubRepository={githubRepository}
          />
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
                  <ChevronRight size={10} className="cv-user__context-chevron" />
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
              <ChiefPromptBubble text={envelope ? envelope.task : (row.text ?? "")} />
              <PromptActions
                row={row}
                text={envelope ? envelope.task : (row.text ?? "")}
                pending={
                  steerControls(row)
                    ? (actions) => (
                        <PendingSteer row={row} send={editQueued}>
                          {actions}
                        </PendingSteer>
                      )
                    : undefined
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
                  steerControls(row)
                    ? (actions) => (
                        <PendingSteer row={row} send={editQueued}>
                          {actions}
                        </PendingSteer>
                      )
                    : undefined
                }
              />
            </>
          )}
          <DeliveryFailure row={row} />
          {row.viaCli && <div className="cv-user__status">{t("transcript.viaCli", { host: row.viaCli })}</div>}
          {row.status && (
            <div className="cv-user__status">
              <span>{row.status}</span>
              {row.queued && (
                <button
                  type="button"
                  className="cv-user__cancel"
                  onClick={() =>
                    void window.cmuxAcpmuxActions?.["chat.harness.cancelPrompt"]?.({ promptId: row.queued })
                  }
                >
                  {t("switch.cancelPrompt")}
                </button>
              )}
            </div>
          )}
        </div>
      );
    }
    return (
      <RevealedMarkdown
        text={row.text ?? ""}
        streaming={row.streaming === true}
        githubRepository={githubRepository}
        messageAt={row.at}
      />
    );
  },
  (previous, next) =>
    previous.row.id === next.row.id &&
    previous.row.version === next.row.version &&
    previous.githubRepository === next.githubRepository,
);
