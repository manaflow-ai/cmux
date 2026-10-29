// The waiting-messages row: several other sessions' waiting messages as one card.
import { memo } from "react";
import { WaitingMessagesCard } from "../conversation/WaitingMessagesCard";
import { type AcpmuxRow, QUEUED_MESSAGE } from "../model";
import { MessageRow } from "./MessageRow";
import { QueuedMessageRow } from "./QueuedMessageRow";
import type { RowProps } from "./rowProps";

/// Several other sessions' waiting messages as one card (conversation/WaitingMessagesCard.tsx): each
/// message draws in it as its own row draws alone.
export const WaitingMessagesRow = memo(
  function WaitingMessagesRow(props: RowProps) {
    const renderMessage = (message: AcpmuxRow) =>
      message.kind === QUEUED_MESSAGE ? (
        <QueuedMessageRow {...props} row={message} />
      ) : (
        <MessageRow {...props} row={message} />
      );
    return <WaitingMessagesCard row={props.row} renderMessage={renderMessage} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
