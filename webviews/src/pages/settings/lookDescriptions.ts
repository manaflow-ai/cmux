// Look Descriptions (`experiments.lookDescriptions`): how each tile in Settings > Appearance > Looks
// describes its look. Leo, 2026-11-27: "im not a fan of the descriptions on our themes and
// whatnot". `phrase` (the default) shows the look's one short tagline; `name` shows only its name
// and preview; `tagged` adds its two or three traits under the tagline ("Dark · Compact").
import { valueOf, type SettingsState } from "./store";

export const LOOK_DESCRIPTIONS_KEY = "experiments.lookDescriptions";

export type LookDescriptions = "phrase" | "name" | "tagged";

/** The chosen variant; anything else reads as the default, `phrase`. */
export function lookDescriptionsOf(state: SettingsState): LookDescriptions {
  const value = valueOf(state, LOOK_DESCRIPTIONS_KEY);
  return value === "name" || value === "tagged" ? value : "phrase";
}

/** A look's tag line: its traits joined by a middle dot, or null when it has none. */
export function traitLine(traits: readonly string[] | undefined): string | null {
  const words = (traits ?? []).map((trait) => trait.trim()).filter(Boolean);
  return words.length > 0 ? words.join(" · ") : null;
}
