import { useMemo } from "react";
import { MoveProgress, type MoveProgressLook } from "./MoveProgress";
import { placeActions, type PlaceClaims } from "./usePlace";
import { useHeaderState } from "../header/headerState";

/// What ships: the card over the composer (MoveProgress.gallery.tsx compares the other looks).
const SHIPPED_MOVE: MoveProgressLook = "card";

/// The chat's move over its composer; nothing while it has none. A move for another chat draws nothing.
export function MoveDock({
  session,
  say,
  claims,
  look = SHIPPED_MOVE,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  /// The queue and draft the page holds, read at a Retry.
  claims?: () => PlaceClaims;
  look?: MoveProgressLook;
}) {
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  const move = place?.move;
  if (!move || !actions || (move.session && session && move.session !== session)) return null;
  return <MoveProgress move={move} look={look} onCancel={actions.cancel} onRetry={actions.retry} />;
}
