import { useMemo } from "react";
import { MoveProgress, type MoveProgressLook } from "./MoveProgress";
import { PlaceControl, type PlaceControlLook } from "./PlaceControl";
import { placeActions } from "./usePlace";
import { useHeaderState } from "../header/headerState";

/// What ships: the chip in the composer's location row, and the card over the composer
/// (PlaceControl.gallery.tsx and MoveProgress.gallery.tsx compare the other looks).
const SHIPPED_CONTROL: PlaceControlLook = "menu";
const SHIPPED_MOVE: MoveProgressLook = "card";

/// The chat's place control, reading `pane.tabState`'s `place`; nothing while the app reports none.
export function PlaceChip({
  session,
  say,
  look = SHIPPED_CONTROL,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  look?: PlaceControlLook;
}) {
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say) : undefined), [session, say]);
  if (!place || !actions) return null;
  return <PlaceControl place={place} look={look} onMode={actions.setMode} />;
}

/// The chat's move over its composer; nothing while it has none. A move for another chat draws nothing.
export function MoveDock({
  session,
  say,
  look = SHIPPED_MOVE,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  look?: MoveProgressLook;
}) {
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say) : undefined), [session, say]);
  const move = place?.move;
  if (!move || !actions || (move.session && session && move.session !== session)) return null;
  return <MoveProgress move={move} look={look} onCancel={actions.cancel} onRetry={actions.retry} />;
}
