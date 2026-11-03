// The one button of the web UI: a variant for its weight and a size from the control scale, so a
// page no longer invents its own "button-primary" (Leo 2026-11-03: "no sense of system at ALL for
// ANYTHING like we're not even looking at some shadcn type stuff"). The API follows shadcn's: a
// `variant` and a `size` prop, and `buttonClass()` (shadcn's `buttonVariants`) for an element that
// must look like a button without being this one (a link, a Base UI trigger's `className`).
// Styles live in ui/button.css, its own file because the agent pane does not load ui.css.
import type { ButtonHTMLAttributes, Ref } from "react";
import { cx } from "./cx";

/** How much weight the action carries. One `primary` per view; `destructive` deletes or stops. */
export type ButtonVariant = "primary" | "secondary" | "outline" | "ghost" | "destructive";

/** Heights from the control scale (`--ds-control-*`): sm 24, md 28, lg 32; `icon` sizes are square. */
export type ButtonSize = "sm" | "md" | "lg" | "icon-sm" | "icon";

export interface ButtonClassOptions {
  variant?: ButtonVariant;
  size?: ButtonSize;
  className?: string;
}

/** The class names of a button of this variant and size, for an element that is not a `Button`. */
export function buttonClass({ variant = "secondary", size = "md", className }: ButtonClassOptions = {}): string {
  return cx("ui-button", "ui-btn", `ui-btn-${variant}`, `ui-btn-${size}`, className);
}

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  ref?: Ref<HTMLButtonElement>;
}

/** A native button with the shared look. `type` defaults to "button", so it never submits a form
 * by accident; pass `type="submit"` for the form's own action. An `icon` size needs `aria-label`. */
export function Button({ variant, size, className, type = "button", ...rest }: ButtonProps) {
  return <button {...rest} type={type} className={buttonClass({ variant, size, className })} />;
}
