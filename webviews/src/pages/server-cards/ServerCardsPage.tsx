// The server page (cmux-page://cmux.server-cards/): the menu bar item's server panel routes, shown in the item's
// popover (ServerPanelPopover.swift).
import { useEffect, useState } from "react";
import type { PageClient } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import { cardOfHash } from "./host";
import { ServerSurfaceHost, serverRouteOf } from "./server/ServerSurfaceHost";

export function ServerCardsPage({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [card, setCard] = useState(() => cardOfHash(location.hash));
  useEffect(() => {
    const onHash = () => setCard(cardOfHash(location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const server = serverRouteOf(card);
  // One host across the server routes: the panel's Health row draws Health from the status already
  // read, in the same frame.
  return server ? <ServerSurfaceHost client={client} strings={strings} route={server} /> : null;
}
