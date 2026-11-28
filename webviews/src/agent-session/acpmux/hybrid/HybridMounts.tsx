// The hybrid controls on the app's real state (RFD 0078). They draw `pane.tabState`'s `place` and
// write only through the place lane's `chatPlace.set` (place/usePlace.ts): Hybrid is its mode
// `auto`, Only in Cloud `cloud`, Only on This Mac `local`. High priority (the lit Hybrid, Keep
// Running) writes through `chatPriority.set`; the app's Rust says whether it holds a slot or waits
// (`place.keep`). With no known plan the app sends no `keep`, and neither mount offers it.
import { useMemo } from "react";
import { useExperimentSwitch } from "../../../experiments/switches";
import { useHeaderState } from "../header/headerState";
import { useT } from "../i18n";
import { placeActions, type PlaceClaims } from "../place/usePlace";
import { CloudTriToggle } from "./CloudTriToggle";
import { placementLine } from "./placementLine";
import { blockedAction, nextPriority } from "./blockedAction";
import { CLOUD_TOGGLE_SWITCH } from "./hybridModel";
import { newTabPin, pickNewTabPin, type NewTabWhere, type NewTabWhereWrites } from "./newTabHybrid";

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
  const on = useExperimentSwitch(CLOUD_TOGGLE_SWITCH);
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  if (!on || !place || !actions) return null;
  const keep = place.keep;
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
      {...(keep
        ? {
            lit: keep.lit,
            waiting: keep.waiting,
            onLitChange: () => actions.setPriority(nextPriority(keep, place.blocked?.why)),
          }
        : {})}
    />
  );
}

/// The New Tab page's control, before a chat exists (newTabHybrid.ts): the page's Where pick, drawn
/// and written through its own rows. Mounted only where AutoCloud is on (the plan and the
/// `cloud.autoCloud` key, default off).
export function NewTabHybridChip({ where, writes }: { where: NewTabWhere; writes: NewTabWhereWrites }) {
  return (
    <CloudTriToggle
      pin={newTabPin(where)}
      look="rainbow"
      form="segments"
      named
      onChange={(pin) => pickNewTabPin(pin, writes)}
    />
  );
}
