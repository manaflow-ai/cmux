// Entry options: named switches a person flips in the gallery header (dark/light lives in the
// shared controls; these are the entry's own: a layout, a platform frame, a child count, a
// thinking disclosure). An option names a prop of a component entry. Its value comes from one
// place, in this order:
//   1. the URL (`opts=<id>:<value>;...`, written only for values the viewer changed);
//   2. the variant's own prop of that name;
//   3. the option's `defaultValue`.
// So a variant stays a named, reproducible state, and a toggle flips one prop of it.
// Values are lower kebab case (`iphone`, `10`); a toggle is `on` or `off`.

export type ToggleOption = {
  /** The prop it sets (and the URL key); lower camel or kebab case. */
  id: string;
  label: string;
  kind: "toggle";
  defaultValue: boolean;
};

export type ChoiceOption = {
  id: string;
  label: string;
  kind: "choice";
  /** Values in display order, each with an optional label. */
  choices: readonly (string | { value: string; label: string })[];
  defaultValue: string;
  /** The prop is a number (a child count, a depth): the value is passed as one. */
  numeric?: boolean;
};

export type GalleryOption = ToggleOption | ChoiceOption;

export type OptionValues = Record<string, string>;

const OPTION_ID = /^[a-zA-Z][a-zA-Z0-9-]*$/;
const OPTION_VALUE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

export const choiceValue = (choice: ChoiceOption["choices"][number]) =>
  typeof choice === "string" ? choice : choice.value;
export const choiceLabel = (choice: ChoiceOption["choices"][number]) =>
  typeof choice === "string" ? choice : choice.label;

/** The `opts` query value as pairs; malformed pairs are dropped. */
export function readOptions(text: string): OptionValues {
  const values: OptionValues = {};
  for (const pair of text.split(";")) {
    const at = pair.indexOf(":");
    const id = pair.slice(0, at);
    const value = pair.slice(at + 1);
    if (at > 0 && OPTION_ID.test(id) && OPTION_VALUE.test(value)) values[id] = value;
  }
  return values;
}

export function writeOptions(values: OptionValues): string {
  return Object.keys(values)
    .filter((id) => OPTION_ID.test(id) && OPTION_VALUE.test(values[id] ?? ""))
    .sort()
    .map((id) => `${id}:${values[id]}`)
    .join(";");
}

/** The option's value as a string in the URL vocabulary. */
function encode(option: GalleryOption, value: unknown): string | undefined {
  if (option.kind === "toggle") return typeof value === "boolean" ? (value ? "on" : "off") : undefined;
  if (typeof value === "number" || typeof value === "string") return String(value);
  return undefined;
}

/** The value a stage shows for `option`: URL, else the variant's prop, else the default. */
export function effectiveOption(option: GalleryOption, values: OptionValues, props: Record<string, unknown>): string {
  const fromUrl = values[option.id];
  if (fromUrl !== undefined && optionAccepts(option, fromUrl)) return fromUrl;
  return encode(option, props[option.id]) ?? encode(option, option.defaultValue)!;
}

export function optionAccepts(option: GalleryOption, value: string): boolean {
  return option.kind === "toggle" ? value === "on" || value === "off" : option.choices.map(choiceValue).includes(value);
}

/** The props a stage renders: the variant's, with every option the URL sets applied. */
export function applyOptions(
  options: readonly GalleryOption[] | undefined,
  values: OptionValues,
  props: Record<string, unknown>,
): Record<string, unknown> {
  if (!options?.length) return props;
  const next = { ...props };
  for (const option of options) {
    const value = values[option.id];
    if (value === undefined || !optionAccepts(option, value)) {
      if (!(option.id in next)) next[option.id] = option.defaultValue;
      continue;
    }
    next[option.id] = option.kind === "toggle" ? value === "on" : option.numeric ? Number(value) : value;
  }
  return next;
}

/** Definition problems, for validateEntries. */
export function validateOptions(options: readonly GalleryOption[]): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();
  for (const option of options) {
    if (!OPTION_ID.test(option.id)) problems.push(`option ${option.id}: invalid id`);
    if (seen.has(option.id)) problems.push(`option ${option.id}: duplicate id`);
    seen.add(option.id);
    if (option.kind === "choice") {
      const values = option.choices.map(choiceValue);
      for (const value of values)
        if (!OPTION_VALUE.test(value)) problems.push(`option ${option.id}: choice ${value} is not lower kebab case`);
      if (!values.includes(option.defaultValue)) problems.push(`option ${option.id}: the default is not a choice`);
    }
  }
  return problems;
}
