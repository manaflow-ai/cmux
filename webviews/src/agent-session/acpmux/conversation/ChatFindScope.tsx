// Find in Chat's state (cx-ncc.86): it lives here, under the pane, so a keystroke in the find bar
// renders the transcript alone, not the composer and header beside it. The pane's page actions
// reach it through `findRef`.
import { type ReactNode, type RefObject, useEffect, useLayoutEffect } from "react";
import type { AcpmuxRow } from "../model";
import { type ChatFind, isFindRow, useChatFind } from "./chatFind";
import { hiddenRowFold } from "./turns";

export function ChatFindScope({
  rows,
  shown,
  openFold,
  findRef,
  children,
}: {
  /// What Find searches: the chat's rows, or the subagent's the transcript shows.
  rows: readonly AcpmuxRow[];
  /// What the transcript draws, so a match in a closed "Worked for" opens it; undefined in a
  /// subagent's view, which has no folds.
  shown: readonly AcpmuxRow[] | undefined;
  openFold: (fold: string) => void;
  findRef: RefObject<ChatFind | undefined>;
  children: (find: ChatFind) => ReactNode;
}) {
  const find = useChatFind(rows);
  findRef.current = find;
  // A view without the transcript (New Tab, replay) has no Find; the page actions then do nothing.
  useEffect(
    () => () => {
      findRef.current = undefined;
    },
    [findRef],
  );
  // A match in a turn's closed "Worked for" opens it, so the transcript draws the row. Before
  // paint, so the transcript scrolls to the match in the same frame.
  const target = find.open ? find.matches[find.active] : undefined;
  useLayoutEffect(() => {
    if (!target || !shown || shown.some((row) => isFindRow(row, target.rowId))) return;
    const fold = hiddenRowFold(rows, shown, target.rowIndex);
    if (fold) openFold(fold);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new current match opens its fold once
  }, [target?.rowId, target?.occurrence]);
  return children(find);
}
