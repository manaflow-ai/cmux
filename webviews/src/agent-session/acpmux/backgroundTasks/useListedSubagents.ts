// The chat's subagents as acpmux lists them (listedSubagents.ts), read while the Background tasks
// panel is open: once on open, then again every few seconds while it stays open, since a subagent
// that starts or ends far from the page's rows changes nothing the page sees. One read is a few
// kilobytes whatever the chat's size (acpmux bounds the ended ones), so a closed panel reads none
// and an open one costs the same for a chat of ten subagents or four thousand.
import { useEffect, useState } from "react";
import type { ListedSubagent, SubagentListing } from "./listedSubagents";

/// How often an open panel reads the list again.
export const LISTED_REFRESH_MS = 4000;

export type ListedSubagents = {
  /// Running then ended; undefined until the first read answers, or when acpmux does not list.
  list?: readonly ListedSubagent[];
  /// The first read for this chat has not answered yet: the panel says it loads, not that nothing
  /// runs.
  loading: boolean;
};

const NONE: ListedSubagents = { loading: false };

export function useListedSubagents(
  read: (() => Promise<SubagentListing | undefined>) | undefined,
  open: boolean,
  sessionId: string | undefined,
): ListedSubagents {
  const [state, setState] = useState<{ sessionId?: string; listed: ListedSubagents }>({ listed: NONE });
  useEffect(() => {
    if (!open || !read || !sessionId) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let last = "";
    let shown: ListedSubagents | undefined;
    setState((was) => (was.sessionId === sessionId ? was : { sessionId, listed: { loading: true } }));
    const settle = (listing: SubagentListing | undefined) => {
      if (!live) return;
      // An unchanged list keeps its array, so the panel's groups are not derived again.
      const key = listing ? JSON.stringify(listing) : "";
      if (key !== last || shown === undefined) {
        last = key;
        shown = { list: listing ? [...listing.running, ...listing.ended] : undefined, loading: false };
        setState({ sessionId, listed: shown });
      }
    };
    // A failed read keeps the last list; the first one stops saying it loads.
    const failed = () => {
      if (live)
        setState((was) => (was.listed.loading ? { sessionId, listed: { ...was.listed, loading: false } } : was));
    };
    const once = () => {
      read()
        .then(settle, failed)
        .finally(() => {
          if (live) timer = setTimeout(once, LISTED_REFRESH_MS);
        });
    };
    once();
    return () => {
      live = false;
      if (timer !== undefined) clearTimeout(timer);
    };
  }, [read, open, sessionId]);
  return open && state.sessionId === sessionId ? state.listed : NONE;
}
