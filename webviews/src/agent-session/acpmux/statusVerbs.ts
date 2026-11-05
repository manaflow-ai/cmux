import { createContext, useContext, useSyncExternalStore } from "react";
import type { Translate } from "./i18n";

/// The default cadence is slow enough to read while a user scans the transcript, without making a
/// long turn look stuck on one word.
export const STATUS_VERB_INTERVAL_MS = 2_400;

export type StatusVerbConfig =
  | { mode: "rotate"; verbs: readonly [] }
  | { mode: "thinking"; verbs: readonly ["Thinking"] }
  | { mode: "custom"; verbs: readonly string[] };

const THINKING_VERBS = ["Thinking"] as const;

export const DEFAULT_STATUS_VERB_CONFIG: StatusVerbConfig = {
  mode: "thinking",
  verbs: THINKING_VERBS,
};

const THINKING_CONFIG: StatusVerbConfig = DEFAULT_STATUS_VERB_CONFIG;

const cleanVerb = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined;
  const verb = value.trim().replace(/\s+/g, " ");
  return verb.length > 0 ? verb : undefined;
};

const verbsFrom = (value: unknown): string[] => {
  const values = Array.isArray(value) ? value : typeof value === "string" ? value.split(",") : [];
  return [...new Set(values.map(cleanVerb).filter((verb): verb is string => verb !== undefined))];
};

/// The setting's mode and comma-separated custom list, as they arrive from ChatDisplay's map.
export function resolveStatusVerbConfig(values: unknown): StatusVerbConfig {
  if (!values || typeof values !== "object" || Array.isArray(values)) return DEFAULT_STATUS_VERB_CONFIG;
  const record = values as Record<string, unknown>;
  const mode = record["agentPane.display.statusVerbs.mode"];
  const custom = record["agentPane.display.statusVerbs.custom"];
  if (mode === "rotate") return { mode: "rotate", verbs: [] };
  if (mode === "thinking") return THINKING_CONFIG;
  if (mode === "custom") {
    const verbs = verbsFrom(custom);
    return verbs.length > 0 ? { mode: "custom", verbs } : THINKING_CONFIG;
  }
  return DEFAULT_STATUS_VERB_CONFIG;
}

const sameConfig = (left: StatusVerbConfig, right: StatusVerbConfig) =>
  left.mode === right.mode &&
  left.verbs.length === right.verbs.length &&
  left.verbs.every((verb, i) => verb === right.verbs[i]);

let current: StatusVerbConfig = DEFAULT_STATUS_VERB_CONFIG;
const listeners = new Set<() => void>();

/// Update the setting from the native display event. The store is intentionally tiny and event
/// driven; status rows do not allocate a timer of their own.
export function configureStatusVerbs(value: unknown): void {
  const next = resolveStatusVerbConfig(value);
  if (sameConfig(next, current)) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

export const StatusVerbContext = createContext<StatusVerbConfig | undefined>(undefined);

/// The configured status verbs, with a context override for deterministic gallery scenes.
export function useStatusVerbConfig(): StatusVerbConfig {
  const provided = useContext(StatusVerbContext);
  const configured = useSyncExternalStore(subscribe, snapshot, snapshot);
  return provided ?? configured;
}

/// Select a verb without reading time or mutating state. A negative elapsed time is treated as the
/// first frame, which keeps a clock correction from selecting a surprising word.
export function statusVerbAt(elapsedMs: number, config: StatusVerbConfig = DEFAULT_STATUS_VERB_CONFIG): string {
  if (config.mode === "thinking" || config.verbs.length === 0) return "Thinking";
  const elapsed = Number.isFinite(elapsedMs) ? Math.max(0, elapsedMs) : 0;
  const index = Math.floor(elapsed / STATUS_VERB_INTERVAL_MS) % config.verbs.length;
  return config.verbs[index] ?? "Thinking";
}

/// Custom words remain verbatim. The built-in per-turn list is English wordplay and is supplied by
/// the conversation context only when the Rotate setting is enabled.
export function statusVerbLabels(t: Translate, config: StatusVerbConfig): readonly string[] {
  if (config.mode === "custom" && config.verbs.length > 0) return config.verbs;
  return [t("thinking")];
}
