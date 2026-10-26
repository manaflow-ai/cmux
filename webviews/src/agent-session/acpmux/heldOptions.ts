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
/// A tiered Fast option's plain tier, as acpmux's session options (fast) or the model catalog's
/// service tiers (priority, pendingSpeed.ts) name it.
const FAST_TIER = /^(fast|priority)$/i;
/// A tiered Fast option's tier with Fast off: the session's standard, the catalog's default.
const STANDARD = /^(standard|default)$/i;
const ULTRA = /ultra/i;

/// The value a Fast pick takes on an option that lists `values` but not the pick itself, read by
/// what the pick means. Off (off, false, standard, default) is the option's off-like or standard
/// value, else its first. A higher tier (ultrafast) is the option's own spelling of it, else none.
/// Anything else is Fast on (on, true, fast, priority; a typed combo's "fast" holds `HELD_FAST_ON`):
/// the option's plain fast tier, else its on-like value, else its second value unless that is a
/// higher tier. On never becomes a higher tier: the user asked for fast, not more.
export function fastValue(value: string, values: readonly string[]): string | undefined {
  if (OFF.test(value) || STANDARD.test(value))
    return values.find((candidate) => OFF.test(candidate) || STANDARD.test(candidate)) ?? values[0];
  if (ULTRA.test(value)) return values.find((candidate) => ULTRA.test(candidate));
  const on = values.find((candidate) => FAST_TIER.test(candidate)) ?? values.find((candidate) => ON.test(candidate));
  if (on !== undefined) return on;
  const second = values[1];
  return second !== undefined && !ULTRA.test(second) && !OFF.test(second) && !STANDARD.test(second)
    ? second
    : undefined;
}

/// The `configId: value` an opened session takes for a held pick, given the options it names: the
/// option with that id, else its option of the same kind (effort, Fast mode) under its own id, a
/// Fast pick as that option spells what it means (its fast tier for Fast on, `fastValue`).
/// Undefined when the session offers no such option,
/// or an effort or Fast option that does not list the value: the pick is the user's, so no other
/// level stands in for it. A pick of another kind goes as held to an option of its id.
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
  if (!option) return undefined;
  if (!kind) return { configId: option.id, value };
  const values = option.options?.map((choice) => choice.value) ?? [];
  if (values.includes(value)) return { configId: option.id, value };
  if (kind === isEffortOption) return undefined;
  const spelled = fastValue(value, values);
  return spelled === undefined ? undefined : { configId: option.id, value: spelled };
}
