import { useLayoutEffect } from "react";

/**
 * A layout effect for the component's first mount only, with the values it mounted with.
 *
 * The React Compiler skips any component with an `eslint-disable react-hooks/...` line in it, and
 * a skipped component rebuilds every child's props on each render. The one disable a mount-only
 * effect needs lives here, so the component that calls this still compiles.
 */
export function useMountLayoutEffect(effect: () => void | (() => void)): void {
  // eslint-disable-next-line react-hooks/exhaustive-deps -- the first mount only, by design
  useLayoutEffect(effect, []);
}
