// The ops the page serves to its host on the page bridge (PageClient.handle; the host calls them
// with PageRouter.callPage and reads the typed reply).
//
// `home.currentSelection` {} -> HomeSelection | null: what the person has open, for the Home dock's
// view switch (Channels -> Messages opens the same conversation and message). The host never reads
// the page URL for it. A page without the op (an older build, or before the page connected to its
// daemon) answers `cmux.protocol.unknown_op`: the host treats that as no selection.
import { useEffect, useLayoutEffect, useRef } from "react";
import type { PageClient } from "../shared/pageClient";

export const CURRENT_SELECTION_OP = "home.currentSelection";

/** The open conversation and, when there is one, the message the person is on. */
export interface HomeSelection {
  /** The open conversation's id (`conv_...`, local or Cloud). */
  conversation: string;
  /** The keyboard's current message (j/k), else the message a link marked, else the root of the
   * open thread. */
  message?: string;
}

/** Serves `home.currentSelection` on the host bridge while the page is mounted. `selection` is
 * null when nothing is open (the narrow page's list pane, no conversation). One narrow effect pair:
 * the op answers the latest committed selection (a layout effect: a host call between a commit and
 * the passive effects still reads it). */
export function useHostSelection(host: PageClient | null, selection: HomeSelection | null): void {
  const latest = useRef(selection);
  useLayoutEffect(() => {
    latest.current = selection;
  }, [selection]);
  useEffect(() => {
    if (!host) return;
    return host.handle(CURRENT_SELECTION_OP, () => (latest.current ? { ...latest.current } : null));
  }, [host]);
}
