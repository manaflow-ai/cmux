// Where the live pane draws the composer hat's marks (hatSide.experiment.ts; Leo, 2026-11-21, on the
// Rolodex hat: "this is uncomfortably tight. didn't we say we wanted to move these to the side or
// smth?"). In the `top` arm (the default) nothing changes: the hat sits over the composer as before.
// In a side arm the marks stand in a rail beside the composer (or on its bottom line, HatRail.tsx),
// and the hat itself, opened on its lines, shows over the composer only while the rail's list
// control holds it open; folding it from its header puts it away again. App.tsx reads this once per
// pane and hands the rail to the composer (ComposerBox.tsx `hatMarks`).
import { useCallback, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { hatSideLook, type HatSide } from "./hatSide.experiment";
import { rememberTrayOpen } from "./trayFoldMemory";

export type HatSidePlace = {
  /// Where the marks stand; undefined: the hat over the composer, as today.
  side: HatSide | undefined;
  /// The rail's list control holds the hat open over the composer.
  listOpen: boolean;
  /// The hat draws over the composer (always in `top`; in a side arm only while its list is open).
  hatShown: boolean;
  /// Shows or puts away the hat, opened on its lines, over the composer.
  onList: (open: boolean) => void;
};

/// `chat`: the chat shown, whose list a press opens (another chat starts with it put away).
/// `marks`: the hat has lines to mark (a plan alone has none, so its hat stays on top).
export function useHatSidePlace(chat: string | undefined, marks: boolean): HatSidePlace {
  const [arm] = useState(() => experimentArm(hatSideLook));
  // The chat whose list is open: switching chats puts it away without an effect.
  const [listFor, setListFor] = useState<string | undefined>(undefined);
  const side = arm !== "top" && marks ? arm : undefined;
  const listOpen = side !== undefined && listFor === (chat ?? "");
  const onList = useCallback(
    (open: boolean) => {
      // The hat mounts on the press: it opens on its lines, as it remembers for this chat.
      if (open) rememberTrayOpen(chat, true);
      setListFor(open ? (chat ?? "") : undefined);
    },
    [chat],
  );
  return { side, listOpen, hatShown: side === undefined || listOpen, onList };
}
