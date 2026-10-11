import { forwardRef, type ButtonHTMLAttributes, type HTMLAttributes, type InputHTMLAttributes } from "react";

export const PickerDialog = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(
  function PickerDialog(props, ref) {
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the anchored surface is not a modal dialog.
    return <div {...props} ref={ref} role="dialog" />;
  },
);

type KeyboardInputProps = InputHTMLAttributes<HTMLInputElement> & {
  keyboard?: InputHTMLAttributes<HTMLInputElement>["onKeyDown"];
};

export const PickerComboboxInput = forwardRef<HTMLInputElement, KeyboardInputProps>(function PickerComboboxInput(
  { keyboard, ...props },
  ref,
) {
  // oxlint-disable-next-line jsx-a11y/no-redundant-roles, jsx-a11y/role-has-required-aria-props -- the picker owns the combobox relationship.
  return <input {...props} ref={ref} role="combobox" onKeyDown={keyboard} />;
});

export function PickerOptionList({ children, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- rich option rows need a listbox container.
    <div {...props} role="listbox">
      {children}
    </div>
  );
}

export interface PickerOptionProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  active: boolean;
  selected?: boolean;
  keyboard?: ButtonHTMLAttributes<HTMLButtonElement>["onKeyDown"];
}

export const PickerOption = forwardRef<HTMLButtonElement, PickerOptionProps>(function PickerOption(
  { active, selected, keyboard, ...props },
  ref,
) {
  return (
    <button
      {...props}
      ref={ref}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- options are rich buttons inside the listbox.
      role="option"
      tabIndex={active ? 0 : -1}
      aria-selected={selected}
      onKeyDown={keyboard}
    />
  );
});

type PickerButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  keyboard?: ButtonHTMLAttributes<HTMLButtonElement>["onKeyDown"];
};

export const PickerButton = forwardRef<HTMLButtonElement, PickerButtonProps>(function PickerButton(
  { keyboard, ...props },
  ref,
) {
  return <button {...props} ref={ref} onKeyDown={keyboard} />;
});
