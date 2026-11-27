// A group of native radio buttons (the browser owns their roles, arrows and focus) that also
// submits: Return opens the checked choice and Escape steps back. Page code renders the radios
// inside; the two keys live here so pages carry no key handlers.
import type { KeyboardEvent, ReactNode } from "react";
import { cx } from "./cx";

export interface ChoiceGroupProps {
  label: string;
  className?: string;
  /** While busy, Return and Escape do nothing. */
  busy?: boolean;
  onSubmit(): void;
  onCancel(): void;
  children: ReactNode;
}

export function ChoiceGroup({ label, className, busy, onSubmit, onCancel, children }: ChoiceGroupProps) {
  const onKeyDown = (event: KeyboardEvent<HTMLFieldSetElement>) => {
    // Cmd, Ctrl and Option chords are the app's.
    if (event.metaKey || event.altKey || event.ctrlKey || busy) return;
    if (!(event.target instanceof HTMLInputElement) || event.target.type !== "radio") return;
    if (event.key === "Enter") {
      event.preventDefault();
      onSubmit();
    } else if (event.key === "Escape") {
      event.preventDefault();
      onCancel();
    }
  };
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Return and Escape on the radios inside.
    <fieldset className={cx("ui-choice-group", className)} aria-label={label} onKeyDown={onKeyDown}>
      {children}
    </fieldset>
  );
}
