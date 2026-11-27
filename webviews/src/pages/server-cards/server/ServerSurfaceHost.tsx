// The server surfaces on their routes: the menu bar popover's panel (`#/server-panel`), Health
// (`#/server-health`) and pairing code (`#/server-pairing`). Each reads the app's status through one
// store and reports its size to the popover (host.ts). Add Server is a native card (AddServerDialog.swift).
import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import { useCardSize } from "../host";
import { ServerHealth, ServerPairing, ServerPanel, type ServerActions } from "./ServerViews";
import { ServerStore } from "./store";
import { ServerRoutes } from "./types";
import "./server.css";

export type ServerRoute = (typeof ServerRoutes)[keyof typeof ServerRoutes];

/** The route a hash names, or null. */
export function serverRouteOf(card: string | null): ServerRoute | null {
  return (Object.values(ServerRoutes) as string[]).includes(card ?? "") ? (card as ServerRoute) : null;
}

function useServerStatus(client: PageClient | null) {
  const [store] = useState(() => new ServerStore(client));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return { store, status: useSyncExternalStore(store.subscribe, store.getSnapshot) };
}

export function ServerSurfaceHost({
  client,
  strings,
  route,
}: {
  client: PageClient | null;
  strings: Strings;
  route: ServerRoute;
}) {
  const { store, status } = useServerStatus(client);
  const actions: ServerActions = {
    send: (intent) => void store.send(intent),
    // Health in the same popover: the popover takes Health's size in the same frame.
    openHealth: () => void (location.hash = `#/${ServerRoutes.health}`),
  };
  return (
    // Keyed by route: each route reports its own size, even one equal to the last route's.
    <Frame key={route} client={client} route={route}>
      {status &&
        (route === ServerRoutes.panel ? (
          <ServerPanel status={status} actions={actions} strings={strings} />
        ) : route === ServerRoutes.health ? (
          <ServerHealth status={status} actions={actions} strings={strings} />
        ) : (
          <ServerPairing status={status} actions={actions} strings={strings} />
        ))}
    </Frame>
  );
}

function Frame({ client, route, children }: { client: PageClient | null; route: ServerRoute; children: ReactNode }) {
  const ref = useRef<HTMLDivElement | null>(null);
  useCardSize(client, route, ref);
  return (
    <div ref={ref} className="sv-frame" data-route={route}>
      {children}
    </div>
  );
}
