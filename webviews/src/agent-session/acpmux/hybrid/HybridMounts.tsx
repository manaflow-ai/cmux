// The hybrid controls on the app's real state (RFD 0078). They draw `pane.tabState`'s `place` and
// write only through the place lane's `chatPlace.set` (place/usePlace.ts): Hybrid is its mode
// `auto`, Only in Cloud `cloud`, Only on This Mac `local`. High priority (the lit Hybrid, Keep
// Running) has no wire yet, so neither mount offers it: no light, no switch, no slot count.
import { useMemo } from "react";
import { useHeaderState } from "../header/headerState";
import { useT } from "../i18n";
import { placeActions, type PlaceClaims } from "../place/usePlace";
import { CloudTriToggle } from "./CloudTriToggle";
import { placementLine } from "./placementLine";
import { blockedAction } from "./blockedAction";

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
      start={place.start}
      onChange={actions.setMode}
      blocked={place.blocked}
      onBlockedClick={blockedAction}
      holders={place.holders}
    />
  );
}
