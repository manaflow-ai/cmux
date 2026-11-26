// The text size and density pick (ui/textSize.ts): five "Aa" tiles drawn at the size each one gives, then three
// density tiles drawn as rows at their spacing. Native radios, so the browser owns their roles, arrow keys and focus.
// Settings > General's first card and the Set Up cmux card draw it; each page passes its own words and writes the
// value its own way (Settings' store, the card's host op).
import type { CSSProperties } from "react";
import { cx } from "./cx";
import {
  PICKER_DENSITIES,
  checkedStep,
  samplePoints,
  textSizeChoices,
  type PickerDensity,
  type TextSizeStep,
} from "./textSize";
import "./textSizePicker.css";

export interface TextSizePickerLabels {
  /** The size group's name ("Text size"). */
  size: string;
  /** The density group's name ("Density"). */
  density: string;
  /** Each step's name. */
  steps: Record<TextSizeStep, string>;
  /** Each density's name. */
  densities: Record<PickerDensity, string>;
}

export interface TextSizePickerProps {
  labels: TextSizePickerLabels;
  /** appearance.metrics.chromeFontSize: points, or null (unset: the density's own size). */
  value: number | null;
  /** The density's id (appearance.density, or a custom density's id, which checks no tile). */
  density: string;
  /** The density's chrome body text in points: the steps are whole points over it. */
  body: number;
  /** A step was picked: its points, or null for Default (remove the key). */
  onSize(points: number | null): void;
  onDensity(id: PickerDensity): void;
  /** Names the radio groups apart when two pickers share a page. */
  name?: string;
  className?: string;
}

export function TextSizePicker({
  labels,
  value,
  density,
  body,
  onSize,
  onDensity,
  name = "text-size",
  className,
}: TextSizePickerProps) {
  const checked = checkedStep(value, body);
  return (
    <div className={cx("ui-text-size", className)}>
      <fieldset className="ui-text-size__group" aria-label={labels.size}>
        <legend className="ui-text-size__legend">{labels.size}</legend>
        <div className="ui-text-size__tiles" data-kind="size">
          {textSizeChoices(body).map((choice) => (
            <label key={choice.step} className="ui-text-size__tile" data-on={checked === choice.step ? "" : undefined}>
              <input
                type="radio"
                className="ui-text-size__radio"
                name={`${name}-size`}
                value={choice.step}
                data-text-size={choice.step}
                aria-label={labels.steps[choice.step]}
                checked={checked === choice.step}
                onChange={() => onSize(choice.points)}
              />
              <span
                className="ui-text-size__sample"
                aria-hidden="true"
                style={{ "--sample": `${samplePoints(choice, body)}px` } as CSSProperties}
              >
                Aa
              </span>
              <span className="ui-text-size__name">{labels.steps[choice.step]}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <fieldset className="ui-text-size__group" aria-label={labels.density}>
        <legend className="ui-text-size__legend">{labels.density}</legend>
        <div className="ui-text-size__tiles" data-kind="density">
          {PICKER_DENSITIES.map((id) => (
            <label key={id} className="ui-text-size__tile" data-on={density === id ? "" : undefined}>
              <input
                type="radio"
                className="ui-text-size__radio"
                name={`${name}-density`}
                value={id}
                data-density-choice={id}
                aria-label={labels.densities[id]}
                checked={density === id}
                onChange={() => onDensity(id)}
              />
              <span className="ui-text-size__rows" data-density={id} aria-hidden="true">
                <span />
                <span />
                <span />
              </span>
              <span className="ui-text-size__name">{labels.densities[id]}</span>
            </label>
          ))}
        </div>
      </fieldset>
    </div>
  );
}
