// The one push button of first-party pages, over Base UI Button (shadcn's Base UI shape: `variant`,
// `size`, `className`, `render`), drawn with the design scale (ui/controls.css), never shadcn's look.
// A hover or press fill covers this control only, never the row around it; while a menu, popover or
// select it opened is open (Base UI's `data-popup-open` on the trigger) it stays lit.
import type { ComponentProps } from "react";
import { Button as BaseButton } from "@base-ui/react/button";
import { useExperimentSwitch } from "../experiments/switches";
import { cx } from "./cx";

/// Settings > Advanced > Experiments `experiments.quietButtons` (off by default): design D2's Quiet
/// default (cmuxterm-hq docs/design/design-system-decisions/D-icons-buttons-accent-motion-keyhints.md,
/// "Quiet is the default: no plate and no outline at rest"). On, a button that names no variant draws
/// `ghost`, which is Quiet already: nothing at rest, the hover fill under the pointer, the pressed fill
/// while held or while its menu is open (ui/controls.css). A button that names its variant is unchanged.
export const QUIET_BUTTONS_SWITCH = "quietButtons";

/// The variant a button that names none draws: `subtle` (today's rest plate), or `ghost` while
/// `experiments.quietButtons` is on.
export function defaultButtonVariant(quiet: boolean): ButtonVariant {
  return quiet ? "ghost" : "subtle";
}

/** ghost: no fill at rest, the hover fill on its own box. subtle: a quiet fill at rest. solid: the
 * theme accent, for the one primary action of a surface. */
export type ButtonVariant = "ghost" | "subtle" | "solid";
/** Heights on the control scale: sm 24, md 28 (a row), lg 32 (comfortable). */
export type ButtonSize = "sm" | "md" | "lg";

export interface ButtonProps extends Omit<ComponentProps<typeof BaseButton>, "className"> {
  className?: string;
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** A square, icon-only button; give it an `aria-label`. */
  icon?: boolean;
  /** A destructive action: the danger role for its text (ghost, subtle) or fill (solid). */
  danger?: boolean;
}

export function Button({
  variant,
  size = "md",
  icon = false,
  danger = false,
  className,
  type = "button",
  ...rest
}: ButtonProps) {
  const quiet = useExperimentSwitch(QUIET_BUTTONS_SWITCH);
  return (
    <BaseButton
      type={type}
      className={cx("ui-button ui-btn", className)}
      data-variant={variant ?? defaultButtonVariant(quiet)}
      data-size={size}
      data-icon={icon ? "" : undefined}
      data-danger={danger ? "" : undefined}
      {...rest}
    />
  );
}
