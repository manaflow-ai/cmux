import { memo } from "react";
import { SuggestedTasks, type OfferActions } from "../offer/SuggestedTasks";
import { callNative } from "../callNative";
import { postNative } from "../native";
import { type RowProps } from "./rowProps";
import { openOfferChat } from "./rowActions";

const offerActions: OfferActions = {
  // The tickets come from the host, which keeps each for its one pick; they ride back with Start.
  start: async (offerId, choice, tickets) => {
    const [modeTicket, effortTicket] = await Promise.all([tickets.mode, tickets.effort]);
    return callNative("chat.offer.start", {
      offerId,
      ...choice,
      ...(modeTicket ? { modeTicket } : {}),
      ...(effortTicket ? { effortTicket } : {}),
    });
  },
  reserve: (intent) => {
    try {
      return postNative<{ ticket?: string }>("transport.gesture", { intent }).then((reply) => reply?.ticket);
    } catch {
      // No native host (the gallery, a test page): no ticket, and the host's gesture check stands.
      return Promise.resolve(undefined);
    }
  },
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
