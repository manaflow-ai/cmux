// What an agent's ACP `modes` are worth as permission modes, the composer's Mode chip.
//
// ACP's Session Config Options supersede Session Modes; an agent that has config options may still
// send `modes` for older clients, as a copy of one of its options. Claude Code's and Codex's copy is
// their `mode` option: their permission modes. Pi's (pi-acp 0.0.33) is its `thought_level` option:
// "Thinking: off" … "Thinking: xhigh", which the effort chip already draws. Those are no Mode (Lawrence
// 2026-11-19: "pi should not have a "mode""), so they are dropped where acpmux's answer enters the
// pane (direct.ts) and every composer reads the agent's real modes, or none.

type ModeList = { availableModes?: readonly { id: string }[] };
type OptionChoices = readonly { value?: unknown; options?: unknown }[];
type ConfigOption = { id?: unknown; category?: unknown; options?: unknown };

/// The agent's `modes`, unless they only copy one of its config options that is not a mode option:
/// then undefined, the agent has no permission modes. Modes with no config options beside them (OpenCode,
/// Gemini) are its real ones.
export function permissionModes<M extends ModeList>(
  modes: M | undefined,
  configOptions: readonly ConfigOption[] | undefined,
): M | undefined {
  const ids = (modes?.availableModes ?? []).map((mode) => mode.id);
  if (ids.length === 0 || !configOptions?.length) return modes;
  const copied = configOptions.some((option) => !isModeOption(option) && sameValues(choiceValues(option.options), ids));
  return copied ? undefined : modes;
}

/// Whether acpmux's harness list row says the harness's chats report no permission modes
/// (`_acpmux/harnesses` `reported`, hub/start_mode.rs `reported_options`: the modes and config
/// options its newest chat reported). Unknown (no row, nothing reported) is not none.
export function reportsNoModes(reported: unknown): boolean {
  if (!reported || typeof reported !== "object") return false;
  const { modes, configOptions } = reported as { modes?: unknown; configOptions?: unknown };
  const options = Array.isArray(configOptions) ? (configOptions as ConfigOption[]) : [];
  const rows = Array.isArray(modes)
    ? (modes as { id?: unknown }[]).filter((mode): mode is { id: string } => typeof mode?.id === "string")
    : [];
  if (rows.length === 0) return options.length > 0;
  return permissionModes({ availableModes: rows }, options) === undefined;
}

/// Whether acpmux's harness list row says the harness's chats report permission modes: modes that
/// are not a copy of another option (OpenCode's Build and Plan, Claude Code's). Unknown is not some.
export function reportsModes(reported: unknown): boolean {
  if (!reported || typeof reported !== "object") return false;
  const { modes, configOptions } = reported as { modes?: unknown; configOptions?: unknown };
  const rows = Array.isArray(modes)
    ? (modes as { id?: unknown }[]).filter((mode): mode is { id: string } => typeof mode?.id === "string")
    : [];
  const options = Array.isArray(configOptions) ? (configOptions as ConfigOption[]) : [];
  return rows.length > 0 && permissionModes({ availableModes: rows }, options) !== undefined;
}

function isModeOption(option: ConfigOption): boolean {
  return option.category === "mode" || option.id === "mode";
}

/// An option's choice values, its groups' included (ACP `SessionConfigSelectGroup`).
function choiceValues(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return (raw as OptionChoices).flatMap((choice) =>
    Array.isArray(choice?.options)
      ? choiceValues(choice.options)
      : typeof choice?.value === "string"
        ? [choice.value]
        : [],
  );
}

function sameValues(values: readonly string[], ids: readonly string[]): boolean {
  if (values.length === 0) return false;
  const set = new Set(values);
  return set.size === new Set(ids).size && ids.every((id) => set.has(id));
}

/// The agent's `modes` with the mode the chat runs now. acpmux's session row (`_acpmux/session_changed`,
/// SessionSummary) names a mode change only as its top-level `currentModeId` and carries no `modes`; the
/// page merges that row into the summary, so `modes.currentModeId` is the one the last detail read
/// named. The row's id is the newer one: /plan, the + menu's Plan row, Toggle Plan Mode and a mode
/// another window or the agent set reach the chips with it.
export function liveModes<M extends { currentModeId?: unknown }>(
  modes: M | undefined,
  currentModeId: unknown,
): M | undefined {
  if (!modes || typeof modes !== "object" || typeof currentModeId !== "string" || !currentModeId) return modes;
  return modes.currentModeId === currentModeId ? modes : { ...modes, currentModeId };
}
