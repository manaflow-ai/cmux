import { memo } from "react";
import { StartedSessionCards } from "../started/StartedSessionCard";
import { type RowProps } from "./rowProps";
import { openOfferChat } from "./rowActions";

/// The chats this chat's agent started, as cards where each was started (started/StartedSessionCard.tsx).
export const StartedSessionsRow = memo(
  function StartedSessionsRow({ row }: RowProps) {
    return row.started?.length ? <StartedSessionCards started={row.started} onOpen={openOfferChat} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
