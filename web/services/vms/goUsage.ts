export { runtimeSecondsWithinPeriod, subscriptionPeriodStart } from "./planUsage";

/** Plus retains one machine, including while paused. */
export const GO_SAVED_VM_LIMIT = 1;
/** A durable marker for clearing runtime caps on pre-Plus machines. */
export const GO_UNLIMITED_RUNTIME_METADATA_KEY = "cmuxPlusUnlimitedRuntime";

/** Drizzle wraps PostgreSQL constraints; inspect only the known public limits. */
export function goCapacityConstraint(cause: unknown): "saved" | "active" | "hours" | "period" | null {
  const seen = new Set<unknown>();
  while (cause && typeof cause === "object" && !seen.has(cause)) {
    seen.add(cause);
    const value = cause as { constraint?: string; cause?: unknown; constraint_name?: string };
    const name = value.constraint ?? value.constraint_name;
    if (name === "cmux_go_saved_limit") return "saved";
    if (name === "cmux_go_active_limit") return "active";
    if (name === "cmux_go_hours_limit") return "hours";
    if (name === "cmux_go_period_unavailable") return "period";
    cause = value.cause;
  }
  return null;
}
