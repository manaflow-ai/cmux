import { memo } from "react";
import { SuggestedTasks, type OfferActions } from "../offer/SuggestedTasks";
import { callNative } from "../callNative";
import { type RowProps } from "./rowProps";
import { openOfferChat } from "./rowActions";

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
