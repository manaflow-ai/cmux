import { createContext, useContext, useSyncExternalStore } from "react";
import type { Translate } from "./i18n";

const VERB_KEYS = {
  Thinking: "thinking",
  Exploring: "turn.live.verb.exploring",
  Sketching: "turn.live.verb.sketching",
  Weighing: "turn.live.verb.weighing",
  Mapping: "turn.live.verb.mapping",
  Checking: "turn.live.verb.checking",
  Reasoning: "turn.live.verb.reasoning",
  Shaping: "turn.live.verb.shaping",
  Connecting: "turn.live.verb.connecting",
  Considering: "turn.live.verb.considering",
} as const;

/// The live line's default personality. These are cmux's own words; they are deliberately not
/// copied from another client. The live line reserves room for the complete localized list.
export const DEFAULT_STATUS_VERBS = [
  "Thinking",
  "Exploring",
  "Sketching",
  "Weighing",
  "Mapping",
  "Checking",
  "Reasoning",
  "Shaping",
  "Connecting",
  "Considering",
] as const;

/// The default cadence is slow enough to read while a user scans the transcript, without making a
/// long turn look stuck on one word.
export const STATUS_VERB_INTERVAL_MS = 2_400;

export type StatusVerbConfig =
  | { mode: "rotate"; verbs: readonly string[] }
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
  if (mode === "rotate") return { mode: "rotate", verbs: DEFAULT_STATUS_VERBS };
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

/// Custom words remain verbatim. A partially translated default list keeps the existing localized
/// Thinking label rather than switching languages during a turn.
export function statusVerbLabels(
  t: Translate,
  language: string,
  config: StatusVerbConfig,
  table: Partial<Record<string, string>> | undefined = globalThis.__cmuxPaneStrings?.[language],
): readonly string[] {
  if (config.mode === "custom" && config.verbs.length > 0) return config.verbs;
  if (
    config.mode === "thinking" ||
    (language !== "en" && !Object.values(VERB_KEYS).every((key) => table?.[key]?.trim()))
  )
    return [t("thinking")];
  // The verb catalog entries are optional until the native catalog carries them. Keep the
  // shipped English defaults readable in the meantime, while using a translated value whenever
  // one is present in a loaded table. Reading the table directly also keeps this fallback
  // independent of the generated StringKey union.
  return DEFAULT_STATUS_VERBS.map((word) => table?.[VERB_KEYS[word]]?.trim() || word);
}
