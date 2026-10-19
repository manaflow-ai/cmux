// The entry's own switches (options.ts): a segmented control for a short choice, a menu for a long
// one, a checkbox for a toggle. Each change rewrites `opts` in the URL, so the stages reload with
// it and the link reproduces the view. A developer tool: its labels are English.
import { Select } from "../../ui/Select";
import { ToolbarToggleGroup } from "../../ui/Toolbar";
import {
  choiceLabel,
  choiceValue,
  effectiveOption,
  optionAccepts,
  readOptions,
  writeOptions,
  type GalleryOption,
} from "../options";

/** Choices up to this many show as a segmented control; more as a menu. */
const SEGMENTED_MAX = 5;

export function EntryOptions({
  options,
  opts,
  props,
  onChange,
}: {
  options: readonly GalleryOption[];
  opts: string;
  /** The current variant's props: an option the URL does not set shows the variant's value. */
  props: Record<string, unknown>;
  onChange: (opts: string) => void;
}) {
  const values = readOptions(opts);
  const set = (option: GalleryOption, value: string) => {
    const next = { ...values };
    // The variant's own value is left out of the URL, as every default is.
    const resting = effectiveOption(option, {}, props);
    if (value === resting) delete next[option.id];
    else next[option.id] = value;
    onChange(writeOptions(next));
  };
  const changed = Object.keys(values).some((id) => options.some((option) => option.id === id));
  return (
    <div className="gallery-options" aria-label="Entry options">
      {options.map((option) => {
        const value = effectiveOption(option, values, props);
        const edited = option.id in values && optionAccepts(option, values[option.id]!);
        if (option.kind === "toggle")
          return (
            <label key={option.id} className="gallery-option gallery-option-toggle" data-edited={edited || undefined}>
              <input
                type="checkbox"
                checked={value === "on"}
                onChange={(event) => set(option, event.target.checked ? "on" : "off")}
              />
              {option.label}
            </label>
          );
        const choices = option.choices.map((choice) => ({ value: choiceValue(choice), label: choiceLabel(choice) }));
        return (
          <div key={option.id} className="gallery-option" data-edited={edited || undefined}>
            <span className="gallery-option-label">{option.label}</span>
            {choices.length <= SEGMENTED_MAX ? (
              <ToolbarToggleGroup
                label={option.label}
                value={value}
                options={choices}
                onValueChange={(next) => set(option, next)}
              />
            ) : (
              <Select
                className="gallery-control-select"
                value={value}
                options={choices}
                onChange={(next) => set(option, next)}
                label={option.label}
              />
            )}
          </div>
        );
      })}
      <button type="button" className="gallery-options-reset" disabled={!changed} onClick={() => onChange("")}>
        Reset options
      </button>
    </div>
  );
}
