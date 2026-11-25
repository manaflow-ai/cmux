import { useMemo } from "react";
import { useHeaderState } from "../header/headerState";
import { placeActions } from "../place/usePlace";
import type { SessionInfoCloudControl } from "./SessionInfoCloud";

/// Session Info's cloud control for the tab's own chat: where it may run. No `setLit`, so the Keep
/// Running row is not drawn until priority has a wire.
export function useSessionInfoCloud(
  session: string | undefined,
  say?: (text: string) => void,
): SessionInfoCloudControl | undefined {
  const { place } = useHeaderState();
  return useMemo(() => {
    if (!place || !session) return undefined;
    const actions = placeActions(session, say);
    return {
      view: { lit: false, pin: place.mode, at: place.at, used: 0, total: 0 },
      setPin: actions.setMode,
    };
  }, [place, session, say]);
}
