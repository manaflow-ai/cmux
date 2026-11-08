// The server card page (cmux-page://cmux.server-cards/): one card per route, shown in the app's one
// floating card panel (WebCardPanel.swift). A new card adds its route here.
import { useEffect, useState } from "react";
import type { PageClient } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import { cardOfHash } from "./host";
import { AddMachineCardHost } from "./add-machine/AddMachineCardHost";
import { ADD_MACHINE_CARD } from "./add-machine/types";
import { PairInviteCardHost } from "./pairInvite/PairInviteCardHost";
import { PAIR_INVITE_CARD } from "./pairInvite/types";
import { ServerSurfaceHost, serverRouteOf } from "./server/ServerSurfaceHost";

export function ServerCardsPage({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [card, setCard] = useState(() => cardOfHash(location.hash));
  useEffect(() => {
    const onHash = () => setCard(cardOfHash(location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  if (card === PAIR_INVITE_CARD) return <PairInviteCardHost client={client} strings={strings} />;
  if (card === ADD_MACHINE_CARD) return <AddMachineCardHost client={client} strings={strings} />;
  const server = serverRouteOf(card);
  // One host across the server routes: the panel's Health row draws Health from the status already
  // read, in the same frame.
  return server ? <ServerSurfaceHost client={client} strings={strings} route={server} /> : null;
}
