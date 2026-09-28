"use client";

import { Switch } from "@base-ui-components/react/switch";

/** Accessible on/off switch styled for the dashboard. */
export function SettingsSwitch({
  checked,
  onCheckedChange,
  disabled = false,
  label,
}: {
  readonly checked: boolean;
  readonly onCheckedChange: (checked: boolean) => void;
  readonly disabled?: boolean;
  /** Accessible name when no visible label is associated. */
  readonly label?: string;
}) {
  return (
    <Switch.Root
      checked={checked}
      onCheckedChange={(next) => onCheckedChange(next)}
      disabled={disabled}
      aria-label={label}
      className="relative inline-flex h-5 w-9 shrink-0 items-center border border-border bg-code-bg transition-colors focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground data-[checked]:border-foreground data-[checked]:bg-foreground data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50"
    >
      <Switch.Thumb className="block size-3.5 translate-x-0.5 bg-foreground transition-transform data-[checked]:translate-x-[1.1rem] data-[checked]:bg-background" />
    </Switch.Root>
  );
}
