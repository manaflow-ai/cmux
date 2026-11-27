import type { AcpmuxRow } from "../model";
import type { NoticeSeverity } from "./agentNotice";

/// The strongest severity among a fold's tools' notices (agentNotice.ts) that its head shows: a fire
/// whenever one is in it, else, when every member is a notice, the strongest of theirs; undefined
/// for a fold whose head keeps the sender's mark. Also whether every member is a notice.
export function foldSeverity(rows: readonly AcpmuxRow[]): { severity?: NoticeSeverity; allNotices: boolean } {
  const severities = rows.map((row) =>
    row.incoming?.kind === "message" ? row.incoming.message.notice?.severity : undefined,
  );
  const allNotices = severities.length > 0 && severities.every(Boolean);
  if (severities.includes("fire")) return { severity: "fire", allNotices };
  if (!allNotices) return { allNotices };
  return { severity: severities.includes("warn") ? "warn" : "info", allNotices };
}
