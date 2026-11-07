// The one push button of first-party pages, over Base UI Button (shadcn's Base UI shape: `variant`,
// `size`, `className`, `render`), drawn with the design scale (ui/controls.css), never shadcn's look.
// A hover or press fill covers this control only, never the row around it; while a menu, popover or
// select it opened is open (Base UI's `data-popup-open` on the trigger) it stays lit.
import type { ComponentProps } from "react";
import { Button as BaseButton } from "@base-ui/react/button";
import { cx } from "./cx";

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
  variant = "subtle",
  size = "md",
  icon = false,
  danger = false,
  className,
  type = "button",
  ...rest
}: ButtonProps) {
  return (
    <BaseButton
      type={type}
      className={cx("ui-button ui-btn", className)}
      data-variant={variant}
      data-size={size}
      data-icon={icon ? "" : undefined}
      data-danger={danger ? "" : undefined}
      {...rest}
    />
  );
}
