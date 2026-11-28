import { Checkbox } from "@base-ui/react/checkbox";
import { cx } from "./cx";

export interface TaskCheckboxProps {
  checked: boolean;
  className?: string;
}

/** Read-only task-list checkbox shared by agent replies and the markdown editor. */
export function TaskCheckbox({ checked, className }: TaskCheckboxProps) {
  return (
    <Checkbox.Root
      checked={checked}
      readOnly
      className={cx(className, checked && "is-checked", "cmux-markdown-checkbox")}
    >
      {checked ? (
        <svg className="cv-checkbox__check" viewBox="0 0 14 14" aria-hidden="true" focusable="false">
          <path d="M3 7.2 5.7 10 11 4.3" />
        </svg>
      ) : null}
    </Checkbox.Root>
  );
}
