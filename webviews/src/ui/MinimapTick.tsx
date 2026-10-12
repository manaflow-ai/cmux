import { forwardRef, type ButtonHTMLAttributes, type KeyboardEvent } from "react";

export interface MinimapTickProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  index: number;
  last: number;
  active: boolean;
  keyboard?: ButtonHTMLAttributes<HTMLButtonElement>["onKeyDown"];
}

export const MinimapTick = forwardRef<HTMLButtonElement, MinimapTickProps>(function MinimapTick(
  { index, last, active, keyboard, ...props },
  ref,
) {
  const handleKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    const to =
      event.key === "ArrowUp"
        ? index - 1
        : event.key === "ArrowDown"
          ? index + 1
          : event.key === "Home"
            ? 0
            : event.key === "End"
              ? last
              : undefined;
    if (to !== undefined) event.preventDefault();
    keyboard?.(event);
  };
  return <button {...props} ref={ref} tabIndex={active ? 0 : -1} onKeyDown={handleKeyDown} />;
});
