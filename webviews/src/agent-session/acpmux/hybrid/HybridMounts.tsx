// The hybrid controls on the app's real state (RFD 0075). They draw `pane.tabState`'s `place` and
// write only through the place lane's `chatPlace.set` (place/usePlace.ts): Hybrid is its mode
// `auto`, Only in Cloud `cloud`, Only on This Mac `local`. High priority (the lit Hybrid, Keep
// Running) has no wire yet, so neither mount offers it: no light, no switch, no slot count.
import { useMemo } from "react";
import { useHeaderState } from "../header/headerState";
import { placeActions, type PlaceClaims } from "../place/usePlace";
import { CloudTriToggle } from "./CloudTriToggle";
import type { SessionInfoCloudControl } from "./SessionInfoCloud";

/// The three-state control in the composer's strip; nothing while the app reports no place.
export function HybridChip({
  session,
  say,
  claims,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  /// The queue and draft the page holds, read at the pick (a move carries them).
  claims?: () => PlaceClaims;
}) {
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  if (!place || !actions) return null;
  return <CloudTriToggle pin={place.mode} look="rainbow" form="segments" named onChange={actions.setMode} />;
}

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
