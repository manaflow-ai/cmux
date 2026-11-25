// The hybrid controls on the app's real state (RFD 0078). They draw `pane.tabState`'s `place` and
// write only through the place lane's `chatPlace.set` (place/usePlace.ts): Hybrid is its mode
// `auto`, Only in Cloud `cloud`, Only on This Mac `local`. High priority (the lit Hybrid, Keep
// Running) has no wire yet, so neither mount offers it: no light, no switch, no slot count.
import { useMemo } from "react";
import { callNative } from "../callNative";
import { useHeaderState } from "../header/headerState";
import { useT, type Translate } from "../i18n";
import { placeName } from "../place/PlaceControl";
import type { PlaceState } from "../place/placeModel";
import { placeActions, type PlaceClaims } from "../place/usePlace";
import { CloudTriToggle } from "./CloudTriToggle";
import type { HybridBlockedWhy } from "./hybridModel";
import type { SessionInfoCloudControl } from "./SessionInfoCloud";

/// Where the chat runs now, in the place lane's own words: the move in flight, else the place the
/// app reports. A pin that already names its place (Only on This Mac, running on this Mac) says
/// nothing twice.
export function placementLine(place: PlaceState, t: Translate): string | undefined {
  if (place.move?.state === "moving") return t("place.faceMoving", { to: place.move.to });
  if (place.mode === "local" && place.at === "local") return undefined;
  if (place.mode === "cloud" && place.at === "cloud" && !place.cloudName) return undefined;
  return placeName(place, t);
}

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
  const t = useT();
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  if (!place || !actions) return null;
  return (
    <CloudTriToggle
      pin={place.mode}
      look="rainbow"
      form="segments"
      named
      where={placementLine(place, t)}
      onChange={actions.setMode}
      blocked={place.blocked}
      onBlockedClick={blockedAction}
      holders={place.holders}
    />
  );
}

/// A blocked control's click: Signed Out opens Sign In (the pane's `palette.auth.signIn`, a connect action). The other
/// reasons have no action wired yet, so their click does nothing.
export function blockedAction(why: HybridBlockedWhy): void {
  if (why === "signed-out") void callNative("action.run", { id: "palette.auth.signIn" }).catch(() => undefined);
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
