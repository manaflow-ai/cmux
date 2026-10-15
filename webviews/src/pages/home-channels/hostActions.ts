// The page's host-callable commands, `window.cmuxHomeActions` (the agent page's `cmuxAcpmuxActions`
// pattern): the host calls one by name with callAsyncJavaScript and reads the answer. The page
// stream `cmux.page.command` carries no answer, so a command that returns a value lives here.
//
// `home.currentSelection` -> HomeSelection | null: what the person has open, for the Home dock's
// view switch (Channels -> Messages opens the same conversation, message and thread). The host
// never reads the page URL for it.
import { useEffect, useRef } from "react";

/** The open conversation and, when there is one, the message and thread the person is on. */
export interface HomeSelection {
  /** The open conversation's id (`conv_...`, local or Cloud). */
  conversation: string;
  /** The keyboard's current message (j/k), else the message a link marked. */
  message?: string;
  /** The root of the open thread sheet. */
  thread?: string;
}

export type HomeActions = Record<string, (params?: Record<string, unknown>) => Promise<unknown>>;

declare global {
  interface Window {
    cmuxHomeActions?: HomeActions;
  }
}

/** Serves `window.cmuxHomeActions` while the page is mounted. `selection` is null when nothing is
 * open (the narrow page's list pane, no conversation). One narrow effect: the latest committed
 * selection is what the command answers. */
export function useHostActions(selection: HomeSelection | null): void {
  const latest = useRef(selection);
  useEffect(() => {
    latest.current = selection;
  }, [selection]);
  useEffect(() => {
    const actions: HomeActions = {
      "home.currentSelection": async () => (latest.current ? { ...latest.current } : null),
    };
    window.cmuxHomeActions = actions;
    return () => {
      if (window.cmuxHomeActions === actions) delete window.cmuxHomeActions;
    };
  }, []);
}
