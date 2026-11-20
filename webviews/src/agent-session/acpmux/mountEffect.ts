import { useLayoutEffect, useState } from "react";

/**
 * A layout effect for the component's first mount only, with the values it mounted with.
 *
 * The React Compiler skips any component or hook with an `eslint-disable react-hooks/...` line in
 * it, and a skipped component rebuilds every child's props on each render. The first render's
 * effect is kept in state, so its one dependency never changes and it runs on mount only, with no
 * disable anywhere: the component calling this still compiles, and so does this hook.
 */
export function useMountLayoutEffect(effect: () => void | (() => void)): void {
  const [mountEffect] = useState(() => effect);
  useLayoutEffect(mountEffect, [mountEffect]);
}
