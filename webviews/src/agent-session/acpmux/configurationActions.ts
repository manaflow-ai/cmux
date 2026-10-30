import { isEffortOption } from "./heldOptions";

export type ConfigurationOption = {
  id: string;
  category?: string | null;
  currentValue?: string;
};

/// Resolves the harness-specific effort option used by `session/set_config_option`.
/// Claude, Codex and adapters use `effort`, `reasoning_effort` or `thought_level`.
export function resolveEffortOption(options: readonly ConfigurationOption[] | undefined, requestedId?: string) {
  if (requestedId) return options?.find((option) => option.id === requestedId);
  return options?.find(isEffortOption);
}

/// A native action must never apply to a newer session that replaced the one
/// the caller targeted. An absent expected id means a pending new chat.
export function configurationSessionMatches(expected: unknown, actual: string | undefined): boolean {
  return typeof expected !== "string" || !expected || expected === actual;
}
