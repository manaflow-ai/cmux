import type { Tripwire } from "./TripwireStatus";

export type TripwireState = { revision: number; turnId?: string; items: Tripwire[] };

/** A bounded declaration, also used by late attach and paginated transcript replay. */
export function readTripwires(value: unknown): TripwireState | undefined {
  if (!value || typeof value !== "object") return;
  const state = value as Record<string, unknown>;
  if (!Number.isSafeInteger(state.revision) || (state.revision as number) < 0 || !Array.isArray(state.items)) return;
  if (state.items.length > 8) return;
  const items: Tripwire[] = [];
  for (const raw of state.items) {
    if (!raw || typeof raw !== "object") return;
    const item = raw as Record<string, unknown>;
    if (typeof item.name !== "string" || !item.name.trim() || item.name.length > 200) return;
    if (typeof item.path !== "string" || !item.path.trim() || item.path.length > 512) return;
    if (item.verdict !== "none" && item.verdict !== "backed" && item.verdict !== "failed") return;
    items.push({
      name: item.name,
      path: item.path,
      verdict: item.verdict,
      ...(typeof item.toolCallId === "string" && { toolCallId: item.toolCallId }),
      ...(typeof item.command === "string" && { command: item.command }),
    });
  }
  return {
    revision: state.revision as number,
    items,
    ...(typeof state.turnId === "string" && { turnId: state.turnId }),
  };
}

/** Loading older history must not turn today's red header back to yesterday's green. */
export function newerTripwires(current: TripwireState | undefined, incoming: TripwireState): TripwireState {
  return current && current.revision >= incoming.revision ? current : incoming;
}
