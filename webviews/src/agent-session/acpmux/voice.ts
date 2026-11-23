// The local host owns the voice session. The page only draws its snapshot and forwards clicks.
import { useSyncExternalStore } from "react";

export type VoicePhase =
  | "idle"
  | "connecting"
  | "listening"
  | "finalizing"
  | "thinking"
  | "speaking"
  | "interrupted"
  | "error";
export type VoiceState = {
  state: VoicePhase;
  enabled: boolean;
  level?: number;
  message?: string;
  restartRequired?: boolean;
};
const phases: readonly string[] = [
  "idle",
  "connecting",
  "listening",
  "finalizing",
  "thinking",
  "speaking",
  "interrupted",
  "error",
];
const idle: VoiceState = { state: "idle", enabled: false };
let current = idle;
const listeners = new Set<() => void>();

/** Retains an initial host push before the composer mounts. Malformed pushes fail closed. */
export function setVoiceState(value: unknown): void {
  const input = value && typeof value === "object" ? (value as Record<string, unknown>) : undefined;
  const next: VoiceState =
    input && typeof input.state === "string" && phases.includes(input.state) && typeof input.enabled === "boolean"
      ? {
          state: input.state as VoicePhase,
          enabled: input.enabled,
          level:
            typeof input.level === "number" && Number.isFinite(input.level)
              ? Math.max(0, Math.min(1, input.level))
              : undefined,
          message: typeof input.message === "string" ? input.message : undefined,
          restartRequired: input.restartRequired === true,
        }
      : idle;
  if (
    current.state === next.state &&
    current.enabled === next.enabled &&
    current.level === next.level &&
    current.message === next.message &&
    current.restartRequired === next.restartRequired
  )
    return;
  current = next;
  for (const listener of listeners) listener();
}

export function voiceState(): VoiceState {
  return current;
}
function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
export function useVoiceState(): VoiceState {
  return useSyncExternalStore(subscribe, voiceState);
}
export function voiceActive(state: VoicePhase): boolean {
  return state !== "idle" && state !== "error";
}
