export interface ReconnectState {
  attempt: number;
  delayMs: number;
}

export type ReconnectEvent = "retry" | "connected";

export function reconnectTransition(
  state: ReconnectState,
  event: ReconnectEvent,
  baseMs = 500,
  maxMs = 8_000,
): ReconnectState {
  if (event === "connected") return { attempt: 0, delayMs: 0 };
  return {
    attempt: state.attempt + 1,
    delayMs: Math.min(baseMs * 2 ** state.attempt, maxMs),
  };
}
