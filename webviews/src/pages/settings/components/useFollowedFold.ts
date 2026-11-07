// A Settings fold whose open state its owner holds (an accordion's parent, the host's store): when
// `open` changes, the change runs Session Info's fold (session-info/foldMotion.ts) on the settle, so the
// body and everything under it move together, and a closing body stays drawn until it has folded away.
// The change is read before the frame draws (a layout effect), so nothing shows a frame of the old or
// the new layout without its motion. Under Reduce Motion it is one frame.
import { useLayoutEffect, useState } from "react";
import { useFoldMotion, type FoldMotion } from "../../../agent-session/acpmux/session-info/foldMotion";

export function useFollowedFold<E extends HTMLElement>(open: boolean): FoldMotion<E> {
  const [shown, setShown] = useState(open);
  const fold = useFoldMotion<E>(shown, () => 0);
  const { toggle } = fold;
  useLayoutEffect(() => {
    if (open !== shown) toggle(open, setShown);
  }, [open, shown, toggle]);
  return fold;
}
