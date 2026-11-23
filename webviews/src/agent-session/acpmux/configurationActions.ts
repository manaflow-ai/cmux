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

/// What an effort pick needs: the session's summary as acpmux last sent it, the switch that holds
/// picks for a chat still starting (harnessSwitch.ts), and the live session's config write.
export type EffortPickDeps = {
  summary?: { sessionId?: string; configOptions?: readonly ConfigurationOption[] };
  switch: {
    pickConfig(configId: string, value: string, live?: { sessionId: string; current?: string }): boolean;
  };
  setConfig(configId: string, value: string): Promise<unknown>;
};

/// `chat.effort`: a level (or another config option, `configId`) for the chat the pane shows.
export async function pickEffort(
  { configId, value, effort, expectedSessionId }: Record<string, unknown>,
  deps: EffortPickDeps,
): Promise<void> {
  const summary = deps.summary;
  if (!configurationSessionMatches(expectedSessionId, summary?.sessionId))
    // l10n-allow: a refusal for the host action's caller, which drops a stale pick; never shown.
    throw new Error("the agent chat session changed");
  const requested = typeof value === "string" && value ? value : String(effort ?? "");
  const asked = typeof configId === "string" && configId ? configId : undefined;
  const resolved = resolveEffortOption(summary?.configOptions, asked);
  // l10n-allow: a refusal for the host action's caller; the picker offers no effort then.
  if (!requested) throw new Error("the session offers no effort option");
  // Before the session opens, acpmux's summary has no options yet while the chips draw the
  // harness's last ones: the switch holds the pick under the id the chip named (it maps a generic
  // `effort` onto the session's own option once it opens, heldOptions.ts) and sends it first.
  const id = resolved?.id ?? asked ?? "effort";
  const live =
    resolved && summary?.sessionId ? { sessionId: summary.sessionId, current: resolved.currentValue } : undefined;
  if (deps.switch.pickConfig(id, requested, live)) return;
  // l10n-allow: a refusal for the host action's caller; the picker offers no effort then.
  if (!resolved) throw new Error("the session offers no effort option");
  await deps.setConfig(resolved.id, requested);
}
