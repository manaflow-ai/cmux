const ATTACH_RECOVERY_DELAYS_MS = [100, 250, 500] as const;
export const ATTACH_RECOVERY_STABLE_MS = 5_000;

export function attachRecoveryDelay(attempt: number): number | null {
  return ATTACH_RECOVERY_DELAYS_MS[attempt] ?? null;
}
