export const VM_RESUME_METADATA_KEY = "cmuxResume";
export const VM_RESUME_CLAIM_TTL_MS = 90_000;

export type VmResumeState = {
  readonly generation: string;
  readonly phase: "pending" | "running" | "paused";
  readonly expiresAt: number;
};

export function vmResumeState(metadata: Record<string, unknown> | null | undefined): VmResumeState | null {
  const value = metadata?.[VM_RESUME_METADATA_KEY];
  if (!value || typeof value !== "object") return null;
  const state = value as Partial<VmResumeState>;
  if (typeof state.generation !== "string" || !state.generation
    || !["pending", "running", "paused"].includes(state.phase ?? "")
    || typeof state.expiresAt !== "number" || !Number.isFinite(state.expiresAt)) return null;
  return state as VmResumeState;
}
