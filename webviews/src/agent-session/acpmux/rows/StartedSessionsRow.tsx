// The `startedSessions` row: the chats this chat's agent started.
import { memo } from "react";
import { StartedSessionCards } from "../started/StartedSessionCard";
import { openOfferChat } from "./rowActions";
import type { RowProps } from "./rowProps";

/// The chats this chat's agent started, as cards where each was started (started/StartedSessionCard.tsx).
export const StartedSessionsRow = memo(
  function StartedSessionsRow({ row }: RowProps) {
    return row.started?.length ? <StartedSessionCards started={row.started} onOpen={openOfferChat} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
