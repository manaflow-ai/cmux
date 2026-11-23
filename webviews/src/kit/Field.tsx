// A labelled one-line field: a label, `ui/Input`, and a hint or an error under it, wired together
// for assistive tech (the label names the input; the hint or error describes it).
import { useId, type ReactNode } from "react";
import { Input, type InputProps } from "../ui/Input";
import { cx } from "../ui/cx";

export interface FieldProps extends Omit<InputProps, "id" | "aria-describedby" | "aria-invalid"> {
  label: ReactNode;
  /** A quiet line under the field. */
  hint?: ReactNode;
  /** Replaces the hint and marks the field invalid. */
  error?: ReactNode;
  className?: string;
}

export function Field({ label, hint, error, className, ...input }: FieldProps) {
  const id = useId();
  const noteId = `${id}-note`;
  const note = error ?? hint;
  return (
    <div className={cx("kit-field", className)}>
      <label className="kit-field-label" htmlFor={id}>
        {label}
      </label>
      <Input
        {...input}
        id={id}
        aria-describedby={note != null ? noteId : undefined}
        aria-invalid={error != null ? true : undefined}
      />
      {note != null && (
        <span className="kit-field-note" id={noteId} data-error={error != null ? "" : undefined}>
          {note}
        </span>
      )}
    </div>
  );
}
