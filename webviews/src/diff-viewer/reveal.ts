// Opens the viewer at one file (D1): a chat's edited-files row opens the diff tab on its turn with
// `payload.revealPath`, the file's path in the repository. Once every file has arrived, the viewer
// unfolds that file and scrolls to it, once per load; the reader moves freely after that.
import { useEffect, useRef } from "react";
import { fileName, type DiffItem } from "../diff-stream";

/** The item of repository path `path`: the file named exactly that, else the one whose path ends
 * with it (a row named from a folder below the repository root); undefined when none or several. */
export function revealItemId(items: readonly DiffItem[], path: string): string | undefined {
  const named = (item: DiffItem) => (item.fileDiff ? fileName(item.fileDiff, "") : "");
  const exact = items.find((item) => named(item) === path);
  if (exact) return exact.id;
  const tail = items.filter((item) => named(item).endsWith(`/${path}`));
  return tail.length === 1 ? tail[0]!.id : undefined;
}

/** Reveals `path` once `ready` (the stream completed) with `reveal`, at most once per mount. */
export function useRevealPath(
  path: string | undefined,
  ready: boolean,
  items: readonly DiffItem[],
  reveal: (itemId: string) => void,
): void {
  const done = useRef(false);
  useEffect(() => {
    if (done.current || !path || !ready) return;
    done.current = true;
    const itemId = revealItemId(items, path);
    if (itemId) reveal(itemId);
  }, [path, ready, items, reveal]);
}
