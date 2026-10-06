import type { ReactNode } from "react";
import { Icon } from "../icons";

/** A native select drawn without its own chrome; the chevron is a sibling glyph. */
export function Select({
  value,
  disabled,
  labelId,
  onChange,
  children,
}: {
  value: string;
  disabled: boolean;
  labelId: string;
  onChange: (value: string) => void;
  children: ReactNode;
}) {
  return (
    <span className="select">
      <select
        className="field"
        value={value}
        disabled={disabled}
        aria-labelledby={labelId}
        onChange={(event) => onChange(event.currentTarget.value)}
      >
        {children}
      </select>
      <Icon name="chevron" />
    </span>
  );
}
