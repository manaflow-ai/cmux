// The memory inbox (acpmux `memory_offer` and `memory_resolved` records): after a turn in which the
// person corrected the agent, acpmux offers up to three facts to add to the project's instructions
// file (CLAUDE.md, AGENTS.md). The card under that turn (MemoryOfferCard.tsx) shows them as a small
// diff with Accept and Dismiss per fact; Accept writes the file through the daemon
// (`_acpmux/memory_resolve`), nothing is committed. This module is the card's state, derived once per
// record (direct.ts) and never per token: an offer, then each resolution that settles some of its
// facts. One offer may be settled one fact at a time, so several resolutions can name it; a fact is
// settled by the first one that names it.

/// The row kind that draws a memory offer (rows/registry.tsx).
export const MEMORY_OFFER = "memoryOffer";

/// A row's id for an offer: one row per offer, updated in place as its facts settle.
export const memoryRowId = (offerId: string) => `memory-${offerId}`;

/// The most facts one offer carries (the daemon's limit; a longer record is cut, never refused).
const MAX_FACTS = 3;

export type MemoryOffer = {
  offerId: string;
  /// The instructions file, relative to the chat's folder (`CLAUDE.md`).
  file: string;
  facts: string[];
  /// A line the file does not have yet that the first Accept adds above the facts.
  heading: string | null;
  /// The file does not exist yet: the first Accept creates it.
  created: boolean;
  accepted: string[];
  dismissed: string[];
  /// Facts a request is settling now (client only): their buttons wait.
  busy?: string[];
  /// The daemon's message for the last request that failed (client only); its facts stay actionable.
  error?: string;
};

export type MemoryFactState = "pending" | "busy" | "accepted" | "dismissed";

export type MemoryCardState = {
  file: string;
  created: boolean;
  /// The heading line the next Accept adds: none once a fact was accepted (the file has it then).
  heading: string | null;
  facts: { text: string; state: MemoryFactState }[];
  /// Facts still waiting for the person (busy ones included).
  pending: number;
  accepted: number;
  /// Every fact is settled: the card is its one-line note.
  settled: boolean;
  error?: string;
};

const strings = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

/// An offer from a `memory_offer` record's data, or undefined for one the card cannot draw (no id,
/// no file, no facts).
export function memoryOfferFromRecord(data: unknown): MemoryOffer | undefined {
  if (!data || typeof data !== "object") return undefined;
  const record = data as Record<string, unknown>;
  const offerId = typeof record.offerId === "string" ? record.offerId : "";
  const file = typeof record.file === "string" ? record.file.trim() : "";
  const facts = [...new Set(strings(record.facts).map((fact) => fact.trim()))].filter(Boolean).slice(0, MAX_FACTS);
  if (!offerId || !file || !facts.length) return undefined;
  const heading = typeof record.heading === "string" && record.heading.trim() ? record.heading.trim() : null;
  return { offerId, file, facts, heading, created: record.created === true, accepted: [], dismissed: [] };
}

/// The offer after a resolution (a `memory_resolved` record's data, or `_acpmux/memory_resolve`'s
/// result): the facts it names that were still open settle; one already settled keeps its first
/// outcome, and a fact the offer does not have is ignored. The facts it settles are no longer busy,
/// and a resolution that settles something clears the last error.
export function settleMemoryOffer(offer: MemoryOffer, data: unknown): MemoryOffer {
  if (!data || typeof data !== "object") return offer;
  const record = data as Record<string, unknown>;
  if (typeof record.offerId === "string" && record.offerId !== offer.offerId) return offer;
  const open = new Set(offer.facts.filter((fact) => !offer.accepted.includes(fact) && !offer.dismissed.includes(fact)));
  const accepted = strings(record.accepted).filter((fact) => open.delete(fact));
  const dismissed = strings(record.dismissed).filter((fact) => open.delete(fact));
  if (!accepted.length && !dismissed.length) return offer;
  const settled = new Set([...accepted, ...dismissed]);
  const busy = offer.busy?.filter((fact) => !settled.has(fact));
  return {
    ...offer,
    accepted: [...offer.accepted, ...accepted],
    dismissed: [...offer.dismissed, ...dismissed],
    busy: busy?.length ? busy : undefined,
    error: undefined,
  };
}

/// The offer while a request settles `facts`: they wait, and the last error goes.
export function memoryRequestStarted(offer: MemoryOffer, facts: readonly string[]): MemoryOffer {
  return { ...offer, busy: [...new Set([...(offer.busy ?? []), ...facts])], error: undefined };
}

/// The offer after a request for `facts` failed: they are actionable again, with the daemon's message.
export function memoryRequestFailed(offer: MemoryOffer, facts: readonly string[], message: string): MemoryOffer {
  const busy = offer.busy?.filter((fact) => !facts.includes(fact));
  return { ...offer, busy: busy?.length ? busy : undefined, error: message || undefined };
}

/// What the card draws for an offer.
export function memoryCardState(offer: MemoryOffer): MemoryCardState {
  const accepted = new Set(offer.accepted);
  const dismissed = new Set(offer.dismissed);
  const busy = new Set(offer.busy);
  const facts = offer.facts.map((text) => ({
    text,
    state: (accepted.has(text)
      ? "accepted"
      : dismissed.has(text)
        ? "dismissed"
        : busy.has(text)
          ? "busy"
          : "pending") as MemoryFactState,
  }));
  const pending = facts.filter((fact) => fact.state === "pending" || fact.state === "busy").length;
  return {
    file: offer.file,
    created: offer.created && accepted.size === 0,
    heading: accepted.size ? null : offer.heading,
    facts,
    pending,
    accepted: accepted.size,
    settled: pending === 0,
    error: offer.error,
  };
}

/// The facts the card can act on now (pending, not busy), in order.
export const actionableFacts = (state: MemoryCardState) =>
  state.facts.filter((fact) => fact.state === "pending").map((fact) => fact.text);
