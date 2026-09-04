import type { ReactNode } from "react";

const inputClass =
  "block w-full border border-border bg-background px-3 py-2 text-sm text-foreground outline-none placeholder:text-muted focus:border-foreground";

export function TextField({
  name,
  label,
  type,
  autoComplete,
  defaultValue,
  placeholder,
  required = true,
  autoFocus = false,
  inputMode,
  pattern,
  maxLength,
  hint,
}: {
  name: string;
  label: string;
  type: "email" | "password" | "text";
  autoComplete?: string;
  defaultValue?: string;
  placeholder?: string;
  required?: boolean;
  autoFocus?: boolean;
  inputMode?: "numeric";
  pattern?: string;
  maxLength?: number;
  hint?: ReactNode;
}) {
  return (
    <label className="mb-3 block">
      <span className="mb-1.5 flex items-baseline justify-between text-[13px] font-medium">
        <span>{label}</span>
        {hint}
      </span>
      <input
        className={inputClass}
        name={name}
        type={type}
        autoComplete={autoComplete}
        defaultValue={defaultValue}
        placeholder={placeholder}
        required={required}
        autoFocus={autoFocus}
        inputMode={inputMode}
        pattern={pattern}
        maxLength={maxLength}
      />
    </label>
  );
}

export function PrimaryButton({ children }: { children: ReactNode }) {
  return (
    <button
      type="submit"
      className="mt-1 flex min-h-10 w-full items-center justify-center bg-foreground px-4 text-sm font-medium text-background hover:opacity-85"
    >
      {children}
    </button>
  );
}

/**
 * Carries the sign-in destination through a POST without exposing it to the
 * form's visible fields. The route handler re-validates it as same-origin,
 * so a tampered value can only cost the visitor their redirect.
 */
export function HiddenReturnTo({ value }: { value: string | null }) {
  if (!value) return null;
  return <input type="hidden" name="after_auth_return_to" value={value} />;
}
