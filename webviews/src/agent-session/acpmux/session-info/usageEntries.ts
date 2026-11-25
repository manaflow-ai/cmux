// What Session Info's Usage draws of the other chats acpmux lists (UsageSection.tsx): each chat that
// reports usage, with its numbers, name, place and harness. The list acpmux sends is new whenever any
// chat anywhere changes (its status, its indicator, its time), which drew every section again on each
// such change while a scroll ran, though Usage shows none of those fields (Leo, 2026-11-06, of the
// transcript's scroll redraws: "I think we should have it be, like, the same for the session info").
// SessionInfo.tsx keeps this projection's identity while it holds the same values (sameValue.ts).
import type { AcpmuxSessionEntry } from "../sessionList";

/// The fields of a listed chat that Usage reads.
export type UsageEntry = Pick<
  AcpmuxSessionEntry,
  "sessionId" | "usageStats" | "peer" | "host" | "displayTitle" | "title" | "name" | "harness"
>;

/// The chats in `all` that report usage, each cut to what Usage draws of it.
export function usageEntries(all: readonly AcpmuxSessionEntry[] | undefined): UsageEntry[] | undefined {
  if (!all) return undefined;
  const out: UsageEntry[] = [];
  for (const entry of all) {
    if (!entry.usageStats) continue;
    const { sessionId, usageStats, peer, host, displayTitle, title, name, harness } = entry;
    out.push({ sessionId, usageStats, peer, host, displayTitle, title, name, harness });
  }
  return out;
}
