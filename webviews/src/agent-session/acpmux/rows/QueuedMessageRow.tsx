import { memo } from "react";
import { QueuedMessageCard } from "../conversation/QueuedMessageCard";
import { type RowProps } from "./rowProps";
import { openSenderChat, replyToMessage } from "./rowActions";

/// Another agent's message waiting in the queue: its received card after the running turn
/// (conversation/QueuedMessageCard.tsx).
export const QueuedMessageRow = memo(
  function QueuedMessageRow({ row, githubRepository }: RowProps) {
    return (
      <QueuedMessageCard
        row={row}
        onOpen={openSenderChat}
        onReply={replyToMessage}
        githubRepository={githubRepository}
      />
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
