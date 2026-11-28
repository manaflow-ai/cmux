import { createContext, useContext, useEffect, useMemo, useSyncExternalStore } from "react";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { AppWidgetsClient, type WidgetsView } from "../../../apps/scene/widgetsClient";
import type { PageClient } from "../../../pages/shared/pageClient";
import { pageHostClient } from "../pageHostClient";

const NOOP_SUBSCRIBE = () => () => undefined;
const EMPTY: WidgetsView = { supported: false, listed: false, widgets: [], tiles: [] };
const EMPTY_READ = () => EMPTY;

/// The widget host for every grid under it, when the page's own host is not the one to use: the
/// gallery and tests draw the whole New Tab page (NewTabScreen) on an in-memory host.
const WidgetsHostContext = createContext<PageClient | null | undefined>(undefined);
export const NewTabWidgetsHost = WidgetsHostContext.Provider;

/** The page's widgets in the New Tab place. `injected` is the gallery's or a test's host. */
export function useNewTabWidgets(injected?: PageClient | null) {
  const provided = useContext(WidgetsHostContext);
  const host = injected === undefined ? provided : injected;
  const client = host === undefined ? (pageHostClient() ?? appPanelsDevClient()) : host;
  const owner = useMemo(() => (client ? new AppWidgetsClient(client, "newtab") : undefined), [client]);
  const view = useSyncExternalStore(
    owner?.subscribe ?? NOOP_SUBSCRIBE,
    owner?.getView ?? EMPTY_READ,
    owner?.getView ?? EMPTY_READ,
  );
  useEffect(() => {
    if (!owner) return;
    owner.start();
    // Native pane retirement can discard the document without unmounting React first. A page that
    // goes into the back/forward cache keeps its mounts (a hidden page's tiles get no ticks), so a
    // restore needs no new list or mount.
    const stop = (event: Event) => {
      if (!(event as PageTransitionEvent).persisted) owner.stop();
    };
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      owner.stop();
    };
  }, [owner]);
  return { client, owner, view };
}
