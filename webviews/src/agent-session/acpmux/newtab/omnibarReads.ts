// The omnibar's late sources (plans/cmux-next/omnibar-suggestions.md, phase B): reads that answer
// after the keystroke that asked, never inside it. The rows draw from what the page already holds
// on every key (launchRows.ts); this adds a typed path's subfolders once the field stays still,
// and a read for older text is dropped when it lands.
import { useEffect, useMemo, useRef, useState } from "react";
import type { FolderListing } from "./launchRows";

/// How long before a typed path's folder is listed: a path is typed a part at a time.
export const FOLDER_LIST_SETTLE_MS = 60;
/// Folder answers kept per page (a path typed back and forth reads each folder once).
const LISTINGS_KEPT = 32;

/// The host's `folder.complete`: the subfolders of an absolute folder, names only.
export type CompleteFolder = (path: string) => Promise<readonly string[] | undefined>;

/// The subfolders of `parent` (absolute), once its listing lands; undefined before that, for no
/// parent and when the host cannot list it. A folder read before shows its last answer at once
/// and is read again each time the path comes back to it, so a folder made since shows.
export function useFolderListing(parent: string | undefined, complete: CompleteFolder | undefined) {
  const [listings, setListings] = useState<ReadonlyMap<string, readonly string[]>>(() => new Map());
  const known = parent ? listings.get(parent) : undefined;
  // `complete` may be a new function on every parent render: keep the latest in a ref, so a render
  // never restarts the wait or drops an answer on its way. Written after commit, never during render.
  const latest = useRef(complete);
  useEffect(() => {
    latest.current = complete;
  });
  const can = Boolean(complete);
  useEffect(() => {
    if (!parent || !can) return undefined;
    let live = true;
    const timer = setTimeout(() => {
      const read = latest.current;
      if (!read) return;
      Promise.resolve(read(parent))
        .then((folders) => {
          if (!live) return;
          const answer = folders ?? [];
          setListings((before) => {
            const was = before.get(parent);
            if (was && sameNames(was, answer)) return before;
            const next = new Map(before);
            next.delete(parent);
            next.set(parent, answer);
            while (next.size > LISTINGS_KEPT) next.delete(next.keys().next().value!);
            return next;
          });
        })
        .catch(() => undefined);
    }, FOLDER_LIST_SETTLE_MS);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [parent, can]);
  return useMemo(
    () => (parent && known ? ({ parent, folders: known } satisfies FolderListing) : undefined),
    [parent, known],
  );
}

function sameNames(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((name, index) => name === b[index]);
}
