// Standalone toggle buttons over Base UI Toggle and Toggle Group, in shadcn's shape (`Toggle` and
// `ToggleGroup` with `variant`, `size`, single or `multiple` choice and `orientation`), drawn with the
// design scale (ui/controls.css, plus ui/toggle.css), never shadcn's look. Usable anywhere, not only
// in a Toolbar (the toolbar keeps its own ToolbarToggleGroup).
// - Toggle: a real button with `aria-pressed`; Space and Return flip it.
// - ToggleGroup: one Tab stop; the arrows move between its toggles (along its orientation, looping,
//   direction-aware), Home and End jump to the ends. Single choice by default; `multiple` lets
//   several stay pressed. The group is named by `aria-label` (a role group).
import { createContext, useContext, type ComponentProps } from "react";
import { Toggle as BaseToggle } from "@base-ui/react/toggle";
import { ToggleGroup as BaseToggleGroup } from "@base-ui/react/toggle-group";
import { cx } from "./cx";
import "./controls.css";
import "./toggle.css";

/** ghost: nothing at rest, the selection fill while pressed. outline: a hairline, filled while pressed.
 * segmented (groups only): one track holding the toggles, the pressed one raised, like Tabs'. */
export type ToggleVariant = "ghost" | "outline" | "segmented";
/** Heights on the control scale: sm 24, md 28 (a row), lg 32. */
export type ToggleSize = "sm" | "md" | "lg";

/** Our parts take a plain class name (Base UI also takes a function of state). */
type Classed<T> = Omit<T, "className"> & { className?: string };

const GroupContext = createContext<{ variant?: ToggleVariant; size?: ToggleSize }>({});

export interface ToggleProps extends Classed<ComponentProps<typeof BaseToggle>> {
  variant?: ToggleVariant;
  size?: ToggleSize;
  /** A square, icon-only toggle; give it an `aria-label`. */
  icon?: boolean;
}

export function Toggle({ variant, size, icon = false, className, type = "button", ...rest }: ToggleProps) {
  const group = useContext(GroupContext);
  return (
    <BaseToggle
      type={type}
      className={cx("ui-button ui-btn ui-toggle-button", className)}
      data-variant={variant ?? group.variant ?? "ghost"}
      data-size={size ?? group.size ?? "md"}
      data-icon={icon ? "" : undefined}
      {...rest}
    />
  );
}

export interface ToggleGroupProps extends Classed<ComponentProps<typeof BaseToggleGroup<string>>> {
  /** The look of every toggle in the group (a toggle's own `variant` wins). */
  variant?: ToggleVariant;
  size?: ToggleSize;
}

export function ToggleGroup({
  variant = "ghost",
  size = "md",
  orientation = "horizontal",
  className,
  ...rest
}: ToggleGroupProps) {
  return (
    <GroupContext value={{ variant, size }}>
      <BaseToggleGroup
        className={cx("ui-toggle-set", className)}
        data-variant={variant}
        data-size={size}
        orientation={orientation}
        {...rest}
      />
    </GroupContext>
  );
}
