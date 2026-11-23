export function isTrustRefusal(error: unknown): boolean {
  // The reasons acpmux's trust gate writes (trust_gate.rs; checked against trust_gate.json).
  const reason = (error as { reason?: unknown } | null)?.reason;
  return reason === "trust.pending" || reason === "trust.untrusted";
}

/// What a trust refusal names: its reason and the folder acpmux asks about.
export type TrustRefusal = { reason: "trust.pending" | "trust.untrusted"; cwd?: string };
/// The pane's handler of every trust refusal (`AcpmuxDirectClient.onTrustRefused`).
export type TrustRoute = (refusal: TrustRefusal, again?: () => void, declined?: () => void) => void;

export function trustRefusal(error: unknown): TrustRefusal | undefined {
  if (!isTrustRefusal(error)) return undefined;
  const fields = error as { reason: TrustRefusal["reason"]; cwd?: unknown };
  return {
    reason: fields.reason,
    ...(typeof fields.cwd === "string" && fields.cwd ? { cwd: fields.cwd } : {}),
  };
}

export function harnessRefusal(entry: { unavailable?: unknown; probeError?: unknown } | undefined): string | undefined {
  for (const reason of [entry?.unavailable, entry?.probeError]) if (typeof reason === "string" && reason) return reason;
  return undefined;
}

/// A `session/new` acpmux refused because the chat's folder profile is not enabled yet
/// (`harness.needs_enable`) or its folder has no Trust answer (`harness.needs_trust`).
export type HarnessBlock = {
  reason: "needs-enable" | "needs-trust";
  harness: string;
  folder: string;
};

export function harnessBlock(error: unknown): HarnessBlock | undefined {
  const data = (error as { data?: unknown } | null)?.data as
    | { reason?: unknown; harness?: unknown; folder?: unknown }
    | undefined;
  const reason =
    data?.reason === "harness.needs_enable"
      ? "needs-enable"
      : data?.reason === "harness.needs_trust"
        ? "needs-trust"
        : undefined;
  if (!reason || typeof data?.harness !== "string" || typeof data.folder !== "string") return undefined;
  return { reason, harness: data.harness, folder: data.folder };
}
