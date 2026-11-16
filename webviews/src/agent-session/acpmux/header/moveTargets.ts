import type { HeaderMoveTarget } from "./headerState";

/** acpmux owns the added-machine list, eligibility and placement words. */
export function readMoveTargets(reply: unknown): HeaderMoveTarget[] {
  const rows = (reply as { targets?: unknown } | null)?.targets;
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((raw): HeaderMoveTarget[] => {
    const row = (raw ?? {}) as Record<string, unknown>;
    if (typeof row.id !== "string" || !row.id || typeof row.label !== "string" || !row.label) return [];
    if (row.kind !== "auto" && row.kind !== "ssh" && row.kind !== "remote") return [];
    return [
      {
        id: row.id,
        label: row.label,
        kind: row.kind,
        ...(typeof row.status === "string" ? { status: row.status } : {}),
        ...(typeof row.reason === "string" && row.reason ? { reason: row.reason } : {}),
      },
    ];
  });
}

/** Keep the existing This Mac and Cloud move paths, then append added peers once each. */
export function mergeMoveTargets(
  native: readonly HeaderMoveTarget[],
  peers?: readonly HeaderMoveTarget[],
): readonly HeaderMoveTarget[] {
  if (!peers) return native;
  const existing = native.filter((row) => row.kind === "local" || row.kind === "cloud");
  const seen = new Set(existing.flatMap((row) => [row.id.toLowerCase(), row.label.toLowerCase()]));
  return [
    ...peers.filter((row) => row.kind === "auto"),
    ...existing,
    ...peers.filter(
      (row) => row.kind !== "auto" && !seen.has(row.id.toLowerCase()) && !seen.has(row.label.toLowerCase()),
    ),
  ];
}

/** Peer routing is carried separately from the local/cloud host-kind label. */
export function moveTargetParams(
  summary?: { peer?: string | null; host?: string | null; hostKind?: string | null } | null,
) {
  const source = summary?.peer || (summary?.hostKind !== "local" ? summary?.host : undefined);
  return {
    ...(source ? { source } : {}),
    ...(summary?.hostKind ? { sourceKind: summary.hostKind } : {}),
  };
}
