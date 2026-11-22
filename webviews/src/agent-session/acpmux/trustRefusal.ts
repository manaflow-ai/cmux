// A prompt acpmux refused because the session's folder has no Trust answer (`trust_gate.rs`): the
// refusal's reason and folder. Moved out of direct.ts so the trust ask and its callers read it
// without the connection client.

export function isTrustRefusal(error: unknown): boolean {
  // The reasons acpmux's trust gate writes (trust_gate.rs; checked against trust_gate.json).
  const reason = (error as { reason?: unknown } | null)?.reason;
  return reason === "trust.pending" || reason === "trust.untrusted";
}

/// What a trust refusal names: its reason and the folder acpmux asks about.
export type TrustRefusal = { reason: "trust.pending" | "trust.untrusted"; cwd?: string };

export function trustRefusal(error: unknown): TrustRefusal | undefined {
  if (!isTrustRefusal(error)) return undefined;
  const fields = error as { reason: TrustRefusal["reason"]; cwd?: unknown };
  return {
    reason: fields.reason,
    ...(typeof fields.cwd === "string" && fields.cwd ? { cwd: fields.cwd } : {}),
  };
}
