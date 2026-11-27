// One text size for cmux's chrome (David Beyer, Nov 20: Settings was overwhelming and had no sidebar font size he
// could find): the sidebar, tabs, menus and chat follow appearance.metrics.chromeFontSize, the chrome body size in
// points over the density's own (Swift `Typography`). Settings > General and the Set Up cmux card offer the same five
// steps and three densities through TextSizePicker; this file is their one model, so both write the same values.

/** A step's id: the radio's value and the catalog key's last part. */
export type TextSizeStep = "smaller" | "default" | "large" | "larger" | "largest";

/** Points over the density's own body size for each step; Default writes nothing (the key is removed). */
const OFFSETS: ReadonlyArray<readonly [TextSizeStep, number | null]> = [
  ["smaller", -1],
  ["default", null],
  ["large", 1],
  ["larger", 2],
  ["largest", 4],
];

/** appearance.metrics.chromeFontSize's range in points (schemas/settings/source/appearance.json). */
export const TEXT_SIZE_RANGE = { min: 10, max: 20 } as const;

/** The densities the picker offers, densest first: the three most people pick (Settings' density card has all). */
export const PICKER_DENSITIES = ["compact", "cozy", "comfortable"] as const;
export type PickerDensity = (typeof PICKER_DENSITIES)[number];

/** Each built-in density's chrome body text in points (Swift `DensityPreset`: Default's 14 times its factor). */
export const DENSITY_BODY_POINTS: Readonly<Record<string, number>> = {
  ultraCompact: 11.2,
  compact: 12.6,
  cozy: 14,
  comfortable: 15.4,
  spacious: 16.8,
};

export type TextSizeChoice = { step: TextSizeStep; points: number | null };

/** The five steps at a density whose body text is `body` points: whole points, inside the setting's range. */
export function textSizeChoices(body: number): TextSizeChoice[] {
  return OFFSETS.map(([step, offset]) => ({
    step,
    points:
      offset === null ? null : Math.min(TEXT_SIZE_RANGE.max, Math.max(TEXT_SIZE_RANGE.min, Math.round(body + offset))),
  }));
}

/** The step a stored value shows as checked: unset is Default; a size no step writes checks none. */
export function checkedStep(value: unknown, body: number): TextSizeStep | null {
  if (typeof value !== "number") return "default";
  return textSizeChoices(body).find((choice) => choice.points === value)?.step ?? null;
}

/** The size a step's sample letters draw at, in points: the step's size, or the density's own for Default. */
export function samplePoints(choice: TextSizeChoice, body: number): number {
  return choice.points ?? body;
}
