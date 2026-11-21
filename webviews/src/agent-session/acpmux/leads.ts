// The leaders (Leo, 2026-11-02: "i need to be able to see and talk to the leaders of every
// respective thing"): the coordinator, its deputies and the area owners. Each starts its lanes
// from its own chat, and acpmux tags every such lane `lane.reportsTo` with that chat's id
// (crates/acpmux/src/hub/lane_reports.rs), so a leader is derived, never listed by hand: a live
// chat that at least one live chat reports to. `acpmux ls --leads` derives the same
// (crates/acpmux/src/cli/run/ls_leads.rs).
import { type AcpmuxSessionEntry, normalizedSessionEntry } from "./sessionList";

export type Lead = {
  entry: AcpmuxSessionEntry;
  /** The live chats that report to it, by name. */
  reports: AcpmuxSessionEntry[];
};

/** A lane names its leader by bare id on its own machine: the pair is the leader's key. */
const key = (peer: string | undefined, id: string) => `${peer ?? ""}\u0000${id}`;

const live = (entry: AcpmuxSessionEntry) => entry.status !== "closed" && !entry.archived && !entry.side;

/** The leaders among `sessions`, the one with the most reports first, then by title. */
export function leaders(sessions: readonly (Record<string, any> & { sessionId: string })[]): Lead[] {
  const entries = sessions.map((raw) => normalizedSessionEntry(raw)).filter(live);
  const reports = new Map<string, AcpmuxSessionEntry[]>();
  for (const entry of entries) {
    if (!entry.reportsTo || entry.reportsTo === entry.sessionId) continue;
    const at = key(entry.peer, entry.reportsTo);
    reports.set(at, [...(reports.get(at) ?? []), entry]);
  }
  const seen = new Set<string>();
  const out: Lead[] = [];
  for (const entry of entries) {
    const at = key(entry.peer, entry.sessionId);
    const below = reports.get(at);
    if (!below || seen.has(at)) continue;
    seen.add(at);
    out.push({ entry, reports: below });
  }
  const title = (lead: Lead) => lead.entry.displayTitle ?? lead.entry.name ?? lead.entry.sessionId;
  return out.sort((a, b) => b.reports.length - a.reports.length || title(a).localeCompare(title(b)));
}
