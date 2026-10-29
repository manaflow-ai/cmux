import type { AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
/// One ACP session config option (`configOptions[]`), as the session summary carries it.
export type ConfigOption = NonNullable<Summary["configOptions"]>[number];

function codexFamily(value: string | undefined): boolean {
  const id = (value ?? "").toLowerCase();
  return id === "codex" || id.startsWith("codex-") || id.startsWith("codex_");
}

/// The config options the composer has no control of its own for: what the Options chip lists.
/// A harness can advertise any select option (a custom harness's `thinking` or `sandbox`); Codex's
/// `collaboration_mode` stays on its command/mode paths instead of becoming a composer chip. The
/// model, effort level, Ultracode and fast mode have their own chips, and a `mode` option
/// duplicates the Access chip when the session also reports modes. An option with one choice has
/// nothing to pick.
export function extraConfigOptions(summary: AcpmuxSnapshot["summary"]): ConfigOption[] {
  const isCodex = codexFamily(summary?.family) || codexFamily(summary?.harness);
  const hasModes = (summary?.modes?.availableModes.length ?? 0) > 0;
  return (summary?.configOptions ?? []).filter((option) => {
    if (option.options.length < 2) return false;
    if (isCodex && (option.id === "collaboration_mode" || option.category === "collaboration_mode")) return false;
    if (option.id === "model" || option.category === "model") return false;
    if (option.category === "thought_level" || option.id === "effort" || option.id === "reasoning_effort") return false;
    if (option.id === "ultracode" || option.id === "fast-mode" || /fast[ _-]?mode/i.test(option.name ?? ""))
      return false;
    if (hasModes && (option.id === "mode" || option.category === "mode")) return false;
    return true;
  });
}

/// An option's current choice name ("Plan"), else its value as the agent wrote it.
export function optionValueName(option: ConfigOption): string | undefined {
  const current = option.options.find((choice) => choice.value === option.currentValue);
  return current ? (current.name ?? current.value) : option.currentValue;
}
