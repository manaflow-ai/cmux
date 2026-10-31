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

/// Where an effort pick goes. The session's own effort option when its summary names one (`live`:
/// set on the open session, or held for the one a switch opens). Else, with a chat still starting
/// (a New Tab before its session reports options), the id the picker sent, only to be held: the
/// switch maps it onto the option that session names (harnessSwitch.ts `heldOptionPick`). A New Tab
/// pick was refused as "the session offers no effort option" before (Lucas 2026-10-30).
export function effortPickOption(
  options: readonly ConfigurationOption[] | undefined,
  requestedId?: string,
): { id: string; current?: string; live: boolean } | undefined {
  const resolved = resolveEffortOption(options, requestedId);
  if (resolved)
    return { id: resolved.id, ...(resolved.currentValue ? { current: resolved.currentValue } : {}), live: true };
  return requestedId ? { id: requestedId, live: false } : undefined;
}

/// A native action must never apply to a newer session that replaced the one
/// the caller targeted. An absent expected id means a pending new chat.
export function configurationSessionMatches(expected: unknown, actual: string | undefined): boolean {
  return typeof expected !== "string" || !expected || expected === actual;
}
