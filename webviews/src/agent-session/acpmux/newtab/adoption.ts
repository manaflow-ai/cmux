// A prewarmed spare page adopted by Cmd-T (plans/cmux-next/new-tab.md section 2.2). The spare
// loads, renders and connects before any tab exists; the host then dispatches the real context
// (AgentPaneView.adoptNewTab). WebKit runs that script before any key the user types after Cmd-T,
// so the remounted screen gets every key.
import { useEffect, useState } from "react";
import { newTabHost, type NewTabHost } from "../NewTabPage";

export const NEW_TAB_ADOPT_EVENT = "acpmux-newtab-adopt";

/// Calls `onAdopt` with each adopt event's context and returns the adoption count, a key that
/// remounts the screen so it starts from the new context.
export function useNewTabAdoption(onAdopt: (host: NewTabHost) => void): number {
  const [generation, setGeneration] = useState(0);
  useEffect(() => {
    const handle = (event: Event) => {
      const host = newTabHost({ newTab: (event as CustomEvent).detail });
      if (!host) return;
      onAdopt(host);
      setGeneration((value) => value + 1);
    };
    window.addEventListener(NEW_TAB_ADOPT_EVENT, handle);
    return () => window.removeEventListener(NEW_TAB_ADOPT_EVENT, handle);
  }, [onAdopt]);
  return generation;
}
