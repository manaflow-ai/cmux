import React from "react";

/** A live session option inside the model picker. Native radios provide arrow navigation and
 * checked state while the popover remains anchored for another choice. */
export function PickerChoiceGroup({
  label,
  name,
  choices,
  current,
  onPick,
  horizontal,
}: {
  label: string;
  name: string;
  choices: readonly { value: string; name?: string }[];
  current?: string;
  onPick(value: string): void;
  horizontal?: boolean;
}) {
  return (
    <fieldset className={horizontal ? "acpmux-picker-speed-options" : "acpmux-picker-reasoning-options"}>
      <legend className={horizontal ? "sr-only" : "text-detail text-muted"}>{label}</legend>
      {choices.map((choice) => {
        const text = choice.name ?? choice.value;
        return (
          <label key={choice.value}>
            <input
              type="radio"
              name={name}
              value={choice.value}
              aria-label={text}
              checked={choice.value === current}
              onChange={() => onPick(choice.value)}
            />
            {text}
          </label>
        );
      })}
    </fieldset>
  );
}
