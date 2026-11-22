import { memo } from "react";
import { type AcpmuxRow, QUEUED_MESSAGE, LANE_NOTICE_BATCH } from "../model";
import { LaneNoticeBatch } from "../conversation/LaneNoticeBatch";
import { PendingMessagesCard } from "../conversation/PendingMessagesCard";
import { type RowProps } from "./rowProps";
import { openSenderChat } from "./rowActions";
import { MessageRow } from "./MessageRow";
import { QueuedMessageRow } from "./QueuedMessageRow";

/// The messages that wait for the agent, as one group (conversation/PendingMessagesCard.tsx): each
/// message draws in it as its own row draws alone.
export const PendingMessagesRow = memo(
  function PendingMessagesRow(props: RowProps) {
    const renderMessage = (message: AcpmuxRow) =>
      message.kind === LANE_NOTICE_BATCH ? (
        <LaneNoticeBatch row={message} renderMessage={renderMessage} />
      ) : message.inboxThread ? (
        <MessageRow {...props} row={message} />
      ) : message.inboxQueue ? (
        <QueuedMessageRow {...props} row={{ ...message, queuedMessage: message.inboxQueue }} />
      ) : message.kind === QUEUED_MESSAGE ? (
        <QueuedMessageRow {...props} row={message} />
      ) : (
        <MessageRow {...props} row={message} />
      );
    return <PendingMessagesCard row={props.row} onOpen={openSenderChat} renderMessage={renderMessage} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
