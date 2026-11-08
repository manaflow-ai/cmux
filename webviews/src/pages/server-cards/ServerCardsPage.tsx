// The server card page (cmux-page://cmux.server-cards/): one card per route, shown in the app's one
// floating card panel (WebCardPanel.swift). A new card adds its route here.
import { useEffect, useState } from "react";
import type { PageClient } from "../shared/pageClient";
import type { Strings } from "../shared/i18n";
import { cardOfHash } from "./host";
import { PairInviteCardHost } from "./pairInvite/PairInviteCardHost";
import { PAIR_INVITE_CARD } from "./pairInvite/types";

export function ServerCardsPage({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [card, setCard] = useState(() => cardOfHash(location.hash));
  useEffect(() => {
    const onHash = () => setCard(cardOfHash(location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  switch (card) {
    case PAIR_INVITE_CARD:
      return <PairInviteCardHost client={client} strings={strings} />;
    default:
      return null;
  }
}
