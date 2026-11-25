import { useLayoutEffect } from "react";
import { acpmuxPerf } from "./perf";

/// Counts one committed render of `name` while measuring (perf.ts `renders`): a render React set
/// aside (an interrupted concurrent pass) drew nothing, so it is counted in a layout effect.
export function useCountedRender(name: string): void {
  useLayoutEffect(() => {
    if (acpmuxPerf.enabled) acpmuxPerf.render(name);
  });
}
