import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import { VM_TRIAL_STARTED_AT_METADATA_KEY } from "./auth";
import {
  resolveVmProGateDecision,
  type VmEntitlements,
} from "./entitlements";
import { vmTrialExpiredResponse } from "./routeHelpers";

/** Minimal shape of a mutable Stack user needed to persist the trial start. */
export type VmTrialMetadataUser = {
  readonly clientReadOnlyMetadata?: unknown;
  update(input: { clientReadOnlyMetadata: Record<string, unknown> }): Promise<unknown>;
};

/**
 * Persist the no-card trial start on the user's Stack metadata, idempotently.
 * Never overwrites an existing start (so the window can't be reset by retrying).
 * Returns the effective start ISO (existing or newly written).
 */
export async function ensureVmTrialStarted(
  user: VmTrialMetadataUser,
  nowIso: string,
): Promise<string> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  const existing = metadata[VM_TRIAL_STARTED_AT_METADATA_KEY];
  if (typeof existing === "string" && existing.trim()) return existing.trim();
  metadata[VM_TRIAL_STARTED_AT_METADATA_KEY] = nowIso;
  await user.update({ clientReadOnlyMetadata: metadata });
  return nowIso;
}

/**
 * Shared Pro-gate for every Cloud VM provisioning entry point (create, base
 * open/reset, fork, restore). Returns a Response to short-circuit the route, or
 * null to proceed:
 * - "allowed" (paid / active trial / gate off) → null, proceed.
 * - "trial_available" (free, no trial yet) → start the no-card trial on Stack
 *   metadata (best-effort; still proceed if the write fails so a Stack blip
 *   never blocks a first VM), then null.
 * - "trial_expired" → 402 vm_trial_expired (the upgrade wall).
 */
export async function enforceVmProGate(input: {
  readonly entitlements: Pick<VmEntitlements, "planId" | "vmTrialStartedAt">;
  readonly userId: string;
  readonly env?: Record<string, string | undefined>;
  readonly nowMs?: number;
}): Promise<Response | null> {
  const env = input.env ?? process.env;
  const decision = resolveVmProGateDecision(input.entitlements, env, input.nowMs);
  if (decision === "trial_expired") return vmTrialExpiredResponse();
  if (decision === "trial_available" && isStackConfigured()) {
    try {
      const serverUser = await getStackServerApp().getUser(input.userId);
      if (serverUser) {
        await ensureVmTrialStarted(
          serverUser as unknown as VmTrialMetadataUser,
          new Date().toISOString(),
        );
      }
    } catch (err) {
      // Fail open: never block a user's first Cloud VM on a Stack write hiccup.
      console.error("[VM] trial start failed", err);
    }
  }
  return null;
}
