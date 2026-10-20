import type { InputHTMLAttributes, KeyboardEvent } from "react";

/// Native fields share Return and Escape wiring without adding a wrapper (Lucas 2026-10-18).
export function inputCommandProps({
  enter,
  escape,
  ignoreComposition = false,
}: {
  enter?: (event: KeyboardEvent<HTMLInputElement>) => void;
  escape?: (event: KeyboardEvent<HTMLInputElement>) => void;
  ignoreComposition?: boolean;
}): Pick<InputHTMLAttributes<HTMLInputElement>, "onKeyDown"> {
  return {
    onKeyDown(event) {
      if (ignoreComposition && event.nativeEvent.isComposing) return;
      if (event.key === "Enter") enter?.(event);
      if (event.key === "Escape") escape?.(event);
    },
  };
}
