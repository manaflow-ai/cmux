import { memo } from "react";
import { ReceivedResult } from "../offer/SuggestedTasks";
import { type RowProps } from "./rowProps";
import { openOfferChat } from "./rowActions";

/// A task's result waiting in the queue: its received line (offer/SuggestedTasks.tsx).
export const OfferResultRow = memo(
  function OfferResultRow({ row }: RowProps) {
    return row.received ? <ReceivedResult result={row.received} onOpen={openOfferChat} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
