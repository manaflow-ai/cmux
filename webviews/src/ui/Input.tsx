// A one-line text field over Base UI Input (it joins a Base UI Field when one wraps it), drawn with
// the design scale (ui/controls.css). Like every text field, focus shows as the caret and a quiet
// edge, never a ring (desktop.css, check-text-focus-rings.py).
import type { ComponentProps } from "react";
import { Input as BaseInput } from "@base-ui/react/input";
import { cx } from "./cx";

/** filled: a quiet fill (Settings' fields). outline: a hairline edge, no fill. plain: neither, for a
 * field that sits inside its own box (a search row in a popup). */
export type InputVariant = "filled" | "outline" | "plain";
/** Heights on the control scale: sm 24, md 28, lg 32. */
export type InputSize = "sm" | "md" | "lg";

export interface InputProps extends Omit<ComponentProps<typeof BaseInput>, "size" | "className"> {
  className?: string;
  variant?: InputVariant;
  size?: InputSize;
}

export function Input({ variant = "filled", size = "md", className, ...rest }: InputProps) {
  return <BaseInput className={cx("ui-field ui-input", className)} data-variant={variant} data-size={size} {...rest} />;
}
