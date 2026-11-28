import { useMemo } from "react";
import { useExperimentSwitch } from "../../../experiments/switches";
import { useHeaderState } from "../header/headerState";
import { placeActions } from "../place/usePlace";
import { CLOUD_TOGGLE_SWITCH } from "./hybridModel";
import type { SessionInfoCloudControl } from "./SessionInfoCloud";

/// Session Info's cloud control for the tab's own chat: where it may run, and Keep Running with the plan's slots when the
/// app sends `keep` (a known plan); without it there is no `setLit`, so that row is not drawn.
export function useSessionInfoCloud(
  session: string | undefined,
  say?: (text: string) => void,
): SessionInfoCloudControl | undefined {
  const on = useExperimentSwitch(CLOUD_TOGGLE_SWITCH);
  const { place } = useHeaderState();
  return useMemo(() => {
    if (!on || !place || !session) return undefined;
    const actions = placeActions(session, say);
    const keep = place.keep;
    if (!keep)
      return { view: { lit: false, pin: place.mode, at: place.at, used: 0, total: 0 }, setPin: actions.setMode };
    return {
      view: { lit: keep.lit, waiting: keep.waiting, pin: place.mode, at: place.at, used: keep.used, total: keep.total },
      setLit: (on: boolean) => actions.setPriority(on ? "high" : "normal"),
      setPin: actions.setMode,
    };
  }, [on, place, session, say]);
}
