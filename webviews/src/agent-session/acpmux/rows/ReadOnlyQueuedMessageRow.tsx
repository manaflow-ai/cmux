import { memo } from "react";
import { IncomingMessageLine } from "../conversation/IncomingMessageCard";
import { type RowProps } from "./rowProps";
import { openSenderChat } from "./rowActions";

export const ReadOnlyQueuedMessageRow = memo(
  function ReadOnlyQueuedMessageRow({ row, githubRepository }: RowProps) {
    if (row.incoming?.kind !== "message") return null;
    // A person's message (a guest's prompt) is drawn whole here too: its text is never read as a
    // lane notice, so nothing it says is hidden from the read-only transcript either.
    const person = row.queuedMessage?.person;
    const whole = Boolean(
      person || row.queuedMessage?.held || row.queuedMessage?.declined || row.incoming.message.fromPerson,
    );
    return (
      <div className="cv-incoming">
        <IncomingMessageLine
          id={row.id}
          message={row.incoming.message}
          messageAt={row.at}
          images={row.images}
          onOpen={openSenderChat}
          githubRepository={githubRepository}
          {...(person ? { person } : {})}
          {...(whole ? { whole: true } : {})}
        />
      </div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.githubRepository === b.githubRepository,
);
