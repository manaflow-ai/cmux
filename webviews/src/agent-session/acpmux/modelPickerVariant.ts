// DEV switch between the model picker designs, so they can be compared side by side. Production
// keeps "current" (ComposerPickers' Picker); a variant shows only when the viewer opts in.
import type { AcpmuxSnapshot } from "./model";
import type { Choice, Combo } from "./ComposerPickers";

export const MODEL_PICKER_VARIANTS = ["current", "cascade", "columns", "recents"] as const;
export type ModelPickerVariant = (typeof MODEL_PICKER_VARIANTS)[number];
export const MODEL_PICKER_VARIANT_KEY = "cmux.acpmux.modelPickerVariant";

const known = (value: unknown): value is ModelPickerVariant =>
  typeof value === "string" && (MODEL_PICKER_VARIANTS as readonly string[]).includes(value);

/// The variant to show: `?picker=` on the dev or mock page, else localStorage
/// `cmux.acpmux.modelPickerVariant`, else "current". Blocked storage reads as unset.
export function modelPickerVariant(search: string = globalThis.location?.search ?? ""): ModelPickerVariant {
  const fromQuery = new URLSearchParams(search).get("picker");
  if (known(fromQuery)) return fromQuery;
  try {
    const stored = globalThis.localStorage?.getItem(MODEL_PICKER_VARIANT_KEY);
    if (known(stored)) return stored;
  } catch {
    // Private windows and blocked storage keep the shipped picker.
  }
  return "current";
}

/// What every variant gets from ComposerPickers. Picks go through `onLand` (model, then its
/// effort once the agent reports that model) and `onEffort`, the same paths the current picker uses.
export type ModelPickerProps = {
  catalog: AcpmuxSnapshot["catalog"];
  harness?: string;
  model?: string;
  /// The chip's text: the current model's name, or its id when the catalog doesn't list it.
  label: string;
  efforts: Choice[];
  effort?: string;
  /// The viewer's recent combos, newest first (any harness; variants keep this harness's).
  recents: Combo[];
  onLand(model: string, effort?: string): void;
  onEffort(value: string): void;
  /// Starts a new chat in another harness; without it, other harnesses are not offered.
  onHarness?(harness: string): void;
};

/// How many recents a variant numbers (keys 1 to this).
export const VARIANT_RECENTS = 4;
/// Rows a level shows before "More…".
export const LEVEL_ROWS = 3;
/// How long the pointer rests on a row before its submenu opens.
export const HOVER_INTENT_MS = 120;
