import { memo } from "react";
import { MemoryOfferCard } from "../conversation/MemoryOfferCard";
import { type RowProps } from "./rowProps";
import { resolveMemory } from "./rowActions";

/// A memory offer under the turn that prompted it (conversation/MemoryOfferCard.tsx): Accept and
/// Dismiss go to the daemon (`_acpmux/memory_resolve`).
export const MemoryOfferRow = memo(
  function MemoryOfferRow({ row }: RowProps) {
    const offer = row.memory;
    return offer ? (
      <MemoryOfferCard offer={offer} onResolve={(accept, dismiss) => resolveMemory(offer.offerId, accept, dismiss)} />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
/// A memory offer in a replayed or read-only subagent transcript: its facts with no buttons, which
/// would act on the live chat.
export const ReadOnlyMemoryOfferRow = memo(
  function ReadOnlyMemoryOfferRow({ row }: RowProps) {
    return row.memory ? <MemoryOfferCard offer={row.memory} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
