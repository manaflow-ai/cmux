// The server surfaces on their routes: the menu bar popover's panel (`#/server-panel`), Health
// (`#/server-health`) and pairing code (`#/server-pairing`), and the Add Server card
// (`#/add-server`, also `#/approver`) on the card panel. Each reads the app's status through one
// store and reports its size to its host (the popover or the card panel, host.ts).
import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import { closeCard, useCardCancel, useCardSize } from "../host";
import {
  AddServerCard,
  ServerHealth,
  ServerPairing,
  ServerPanel,
  type AddServerActions,
  type ServerActions,
} from "./ServerViews";
import { ServerStore } from "./store";
import { ServerRoutes } from "./types";
import "./server.css";

export type ServerRoute = (typeof ServerRoutes)[keyof typeof ServerRoutes];

/** The route a card name maps to (`approver` is the Add Server card's other name), or null. */
export function serverRouteOf(card: string | null): ServerRoute | null {
  if (card === "approver") return ServerRoutes.addServer;
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
  const close = () => closeCard(client, route);
  const actions: ServerActions = {
    send: (intent) => void store.send(intent),
    // Health in the same popover: the popover takes Health's size in the same frame.
    openHealth: () => void (location.hash = `#/${ServerRoutes.health}`),
  };
  const addServer: AddServerActions = {
    setCode: (code) => void store.setCode(code),
    setName: (name) => void store.setName(name),
    setTeam: (team) => void store.setTeam(team),
    setRunChief: (on) => void store.setRunChief(on),
    cancel: () => {
      void store.cancel();
      close();
    },
    done: () => {
      void store.cancel();
      close();
    },
  };
  return (
    // Keyed by route: each route reports its own size, even one equal to the last route's.
    <Frame key={route} client={client} route={route}>
      {status &&
        (route === ServerRoutes.panel ? (
          <ServerPanel status={status} actions={actions} strings={strings} />
        ) : route === ServerRoutes.health ? (
          <ServerHealth status={status} actions={actions} strings={strings} />
        ) : route === ServerRoutes.pairing ? (
          <ServerPairing status={status} actions={actions} strings={strings} />
        ) : (
          <>
            <CardCancel client={client} cancel={addServer.cancel} />
            <AddServerCard status={status} actions={addServer} strings={strings} />
          </>
        ))}
    </Frame>
  );
}

/** Escape on the card panel is the Add Server card's Cancel. Only there: on the popover routes
 * Escape must reach the popover, which closes itself. */
function CardCancel({ client, cancel }: { client: PageClient | null; cancel: () => void }) {
  useCardCancel(client, cancel);
  return null;
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
