/**
 * Shared class names for settings surfaces. The dashboard uses square,
 * bordered controls; these helpers keep every settings page consistent.
 */
export type SettingsButtonVariant = "primary" | "secondary" | "danger" | "ghost";

const focusRing =
  "focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground";

const variantClass: Record<SettingsButtonVariant, string> = {
  primary: "border border-foreground bg-foreground text-background hover:opacity-90",
  secondary: "border border-border bg-background text-foreground hover:bg-code-bg",
  danger:
    "border border-red-600 bg-red-600 text-white hover:bg-red-700 dark:border-red-500 dark:bg-red-500",
  ghost: "border border-transparent text-muted hover:bg-code-bg hover:text-foreground",
};

export function settingsButtonClass(
  variant: SettingsButtonVariant = "secondary",
  size: "sm" | "md" = "md",
): string {
  const sizing = size === "sm" ? "px-2 py-1 text-xs" : "px-3 py-1.5 text-sm";
  return `inline-flex items-center justify-center gap-1.5 ${sizing} ${variantClass[variant]} ${focusRing} disabled:cursor-not-allowed disabled:opacity-50`;
}

export const settingsInputClass =
  `w-full min-w-0 border border-border bg-background px-2 py-1.5 text-sm text-foreground placeholder:text-muted ${focusRing} disabled:opacity-50`;

export const settingsLabelClass = "block text-xs text-muted";
