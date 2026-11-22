// Toolbars over Base UI Toolbar: one Tab stop, arrows move between controls (direction-aware),
// each icon control named by `label` with a tooltip that repeats it.
import { lazy, Suspense, useRef, useState, type ReactNode } from "react";
import { Toolbar as BaseToolbar } from "@base-ui/react/toolbar";
import { ToggleGroup } from "@base-ui/react/toggle-group";
import { Toggle } from "@base-ui/react/toggle";

// A toolbar button's hint is an AnchoredCard (Base UI Tooltip) that loads on first use, so the
// page's open path carries no Floating UI; the button itself never remounts, so focus stays put.
// The hint only repeats the button's accessible name (`label`), which is there from the start.
const LazyCard = lazy(() => import("./Tooltip").then((module) => ({ default: module.AnchoredCard })));

/** Hint timing: the first hint waits, the next one within `GROUP_MS` shows at once. */
const HINT_DELAY_MS = 500;
const GROUP_MS = 400;
let lastHintAt = 0;

function useHint() {
  const [anchor, setAnchor] = useState<Element | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const clear = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
  };
  const show = (element: Element) => {
    clear();
    const wait = Date.now() - lastHintAt < GROUP_MS ? 0 : HINT_DELAY_MS;
    timer.current = setTimeout(() => setAnchor(element), wait);
  };
  const hide = () => {
    clear();
    if (anchor) lastHintAt = Date.now();
    setAnchor(null);
  };
  return { anchor, show, hide };
}
import { cx } from "./cx";

export function Toolbar({ label, className, children }: { label: string; className?: string; children: ReactNode }) {
  return (
    <BaseToolbar.Root className={cx("ui-toolbar", className)} aria-label={label}>
      {children}
    </BaseToolbar.Root>
  );
}

export interface ToolbarButtonProps {
  /** The accessible name; also the tooltip. */
  label: string;
  className?: string;
  disabled?: boolean;
  /** Show the tooltip (default when the button has only an icon or a glyph). */
  tooltip?: boolean;
  /** The button marks the current item of a set (`aria-current`), e.g. the visible section. */
  current?: boolean;
  /** A pointer press leaves focus where it was (the button acts on another view). */
  keepsFocus?: boolean;
  onPress?(): void;
  children: ReactNode;
}

export function ToolbarButton({
  label,
  className,
  disabled,
  tooltip = true,
  current,
  keepsFocus,
  onPress,
  children,
}: ToolbarButtonProps) {
  const hint = useHint();
  return (
    <>
      <BaseToolbar.Button
        className={cx("ui-button ui-toolbar-button", className)}
        aria-label={label}
        aria-current={current || undefined}
        disabled={disabled}
        onMouseDown={keepsFocus ? (event) => event.preventDefault() : undefined}
        // A disabled toolbar button stays focusable so arrows do not skip over it silently.
        focusableWhenDisabled
        onClick={() => onPress?.()}
        onMouseEnter={tooltip ? (event) => hint.show(event.currentTarget) : undefined}
        onMouseLeave={tooltip ? hint.hide : undefined}
        onPointerDown={tooltip ? hint.hide : undefined}
        // The hint shows for keyboard focus only (a click focuses without a ring, and without one).
        onFocus={
          tooltip
            ? (event) => event.currentTarget.matches(":focus-visible") && hint.show(event.currentTarget)
            : undefined
        }
        onBlur={tooltip ? hint.hide : undefined}
        onKeyDown={tooltip ? (event) => event.key === "Escape" && hint.anchor && hint.hide() : undefined}
      >
        {children}
      </BaseToolbar.Button>
      {hint.anchor ? (
        <Suspense fallback={null}>
          <LazyCard anchor={hint.anchor} className="ui-hint">
            {label}
          </LazyCard>
        </Suspense>
      ) : null}
    </>
  );
}

export interface ToolbarToggleGroupProps {
  label: string;
  value: string;
  options: ReadonlyArray<{ value: string; label: string }>;
  className?: string;
  onValueChange(value: string): void;
}

/** A single-choice group of toggle buttons inside a toolbar (each `aria-pressed`). */
export function ToolbarToggleGroup({ label, value, options, className, onValueChange }: ToolbarToggleGroupProps) {
  return (
    <ToggleGroup
      className={cx("ui-toggle-group", className)}
      aria-label={label}
      value={[value]}
      onValueChange={(next) => {
        const chosen = next[0];
        if (typeof chosen === "string" && chosen !== value) onValueChange(chosen);
      }}
    >
      {options.map((option) => (
        <BaseToolbar.Button
          key={option.value}
          render={<Toggle value={option.value} />}
          className="ui-button ui-toolbar-button ui-toggle"
        >
          {option.label}
        </BaseToolbar.Button>
      ))}
    </ToggleGroup>
  );
}

export function ToolbarGroup({ label, children }: { label?: string; children: ReactNode }) {
  return (
    <BaseToolbar.Group className="ui-toolbar-group" aria-label={label}>
      {children}
    </BaseToolbar.Group>
  );
}

export function ToolbarSeparator() {
  return <BaseToolbar.Separator className="ui-separator" />;
}
