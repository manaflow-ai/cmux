// An on/off switch over Base UI Switch (role switch, Space toggles, a hidden input for forms), drawn
// with the design scale (ui/controls.css). The thumb slides on the quick motion step and jumps under
// Reduce Motion; there is no loop, timer or observer.
import type { ComponentProps } from "react";
import { Switch as BaseSwitch } from "@base-ui/react/switch";
import { cx } from "./cx";

/** Track heights: sm 16, md 20, lg 24 (widths 28, 32, 40). */
export type SwitchSize = "sm" | "md" | "lg";

export interface SwitchProps extends Omit<ComponentProps<typeof BaseSwitch.Root>, "className"> {
  className?: string;
  size?: SwitchSize;
}

export function Switch({ size = "md", className, ...rest }: SwitchProps) {
  return (
    <BaseSwitch.Root className={cx("ui-switch", className)} data-size={size} {...rest}>
      <BaseSwitch.Thumb className="ui-switch-thumb" />
    </BaseSwitch.Root>
  );
}
