import { HELD_EFFORT_ID, isEffortOption } from "./heldOptions";

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

/// Where an effort pick goes: the harness switch (a held pick for the session it starts, or a live
/// pick drawn until the session answers) and acpmux's `session/set_config_option`.
export type EffortPickRoute = {
  pickConfig(configId: string, value: string, live?: { sessionId: string; current?: string }): boolean;
  setConfig(configId: string, value: string): Promise<void>;
};

/// The pane's `chat.effort` action (App.tsx): picks `value` on the session's effort option.
///
/// Before the chat has a session (the Home and New Tab composers, a harness still starting) the page's
/// summary names no options, so there is no option to resolve yet: the pick is held on the harness
/// switch under the id the picker asked for (the generic `effort` when it knew none), which maps it
/// onto the option the session names once it opens (heldOptions.ts). It used to be refused for want of
/// an option, so a Home pick never reached the switch and the chip fell back to the level the harness's
/// last session reported (https://github.com/manaflow-ai/cmux/issues/38173).
export async function pickEffort(
  params: { configId?: unknown; value?: unknown; effort?: unknown; expectedSessionId?: unknown },
  summary: { sessionId?: string; configOptions?: readonly ConfigurationOption[] } | undefined,
  route: EffortPickRoute,
): Promise<void> {
  if (!configurationSessionMatches(params.expectedSessionId, summary?.sessionId))
    // l10n-allow: a refusal for the host action's caller, which drops a stale pick; never shown.
    throw new Error("the agent chat session changed");
  const requested =
    typeof params.value === "string" && params.value ? params.value : String(params.effort ?? "");
  const asked = typeof params.configId === "string" && params.configId ? params.configId : undefined;
  const resolved = resolveEffortOption(summary?.configOptions, asked);
  // l10n-allow: a refusal for the host action's caller; the picker offers no effort then.
  if (!resolved || !requested) throw new Error("the session offers no effort option");
  const live = summary?.sessionId ? { sessionId: summary.sessionId, current: resolved.currentValue } : undefined;
  if (!route.pickConfig(resolved.id, requested, live)) await route.setConfig(resolved.id, requested);
}
