import { useEffect, useRef } from "react";
import { t } from "../i18n";

interface InlineRenameProps {
  value: string;
  onChange(value: string): void;
  onCommit(): void;
  onCancel(): void;
}

export function InlineRename({ value, onChange, onCommit, onCancel }: InlineRenameProps) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    ref.current?.focus();
    ref.current?.select();
  }, []);

  return (
    <input
      aria-label={t("renameValue")}
      className="inline-rename"
      onChange={(event) => onChange(event.target.value)}
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => {
        event.stopPropagation();
        if (event.key === "Enter") onCommit();
        if (event.key === "Escape") onCancel();
      }}
      ref={ref}
      value={value}
    />
  );
}
