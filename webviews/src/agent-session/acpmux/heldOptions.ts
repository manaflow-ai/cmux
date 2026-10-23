// What kind of option an agent's config option is (its effort, its Fast mode), and how a pick held
// before a chat has a session lands on the session that opens. Before the session the composer
// knows what was picked ("high", Fast on) but not always the id the agent names the option by, or
// whether it offers it: the harness switch holds the pick under its kind's usual id and, once the
// session opens and names its options, sends it under that session's own id and values, before the
// first prompt (harnessSwitch.ts `run`).

type ConfigOption = {
  id: string;
  name?: string | null;
  category?: string | null;
  options?: readonly { value: string }[];
};

/// The id a held effort pick goes under when the composer has no session option to name it.
export const HELD_EFFORT_ID = "effort";
/// The id a held Fast pick goes under when the composer has no session option to name it.
export const HELD_FAST_ID = "fast-mode";
/// The value a held Fast pick turns it on with, when the composer has no session option.
export const HELD_FAST_ON = "on";

/// The session's reasoning option, whatever the harness calls it.
export function isEffortOption(option: { id: string; category?: string | null }): boolean {
  return option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort";
}

/// The session's Fast mode option, whatever the harness calls it.
export function isFastModeOption(option: { id: string; name?: string | null }): boolean {
  return (
    option.id === "fast-mode" ||
    option.id === "fast_mode" ||
    option.id === "fast" ||
    /fast[ _-]?mode/i.test(option.name ?? "")
  );
}

const ON = /^(on|true|enabled)$/i;
const OFF = /^(off|false|disabled)$/i;

/// The `configId: value` an opened session takes for a held pick, given the options it names: the
/// option with that id, else its option of the same kind (effort, Fast mode) under its own id, a
/// Fast pick's on or off as that option spells it. Undefined when the session offers no option of
/// that kind. A pick of any other kind goes as it was held.
export function heldOptionPick(
  configId: string,
  value: string,
  offered: readonly ConfigOption[],
): { configId: string; value: string } | undefined {
  const kind = isEffortOption({ id: configId })
    ? isEffortOption
    : isFastModeOption({ id: configId })
      ? isFastModeOption
      : undefined;
  const option = offered.find((candidate) => candidate.id === configId) ?? (kind && offered.find(kind));
  if (!option) return kind ? undefined : { configId, value };
  const values = option.options?.map((choice) => choice.value) ?? [];
  if (!kind || kind !== isFastModeOption || values.length === 0 || values.includes(value))
    return { configId: option.id, value };
  const spelled = ON.test(value)
    ? values.find((candidate) => ON.test(candidate))
    : OFF.test(value)
      ? values.find((candidate) => OFF.test(candidate))
      : undefined;
  return spelled === undefined ? undefined : { configId: option.id, value: spelled };
}
