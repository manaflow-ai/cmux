// The `sessionOffer` row: an agent's suggested tasks.
import { memo } from "react";
import { callNative } from "../callNative";
import { SuggestedTasks, type OfferActions } from "../offer/SuggestedTasks";
import { openOfferChat } from "./rowActions";
import type { RowProps } from "./rowProps";

const offerActions: OfferActions = {
  start: (offerId, worktree) => callNative("chat.offer.start", { offerId, worktree }),
  here: (offerId) => callNative("chat.offer.here", { offerId }),
  dismiss: (offerId) => callNative("chat.offer.dismiss", { offerId }),
  open: openOfferChat,
};

/// An agent's suggested tasks (offer/SuggestedTasks.tsx); the reducer draws them only with Labs
/// preview features or the session-offer experiment on (offer/offersShown.ts).
export const SessionOfferRow = memo(
  function SessionOfferRow({ row }: RowProps) {
    return row.offers?.length ? <SuggestedTasks offers={row.offers} actions={offerActions} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
