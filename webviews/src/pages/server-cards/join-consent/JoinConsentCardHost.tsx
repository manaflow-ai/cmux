// The join consent ask on its route (`#/join-consent`), on a panel of its own: out of screen capture,
// over every window, key only for a click on its native Allow. The host's status through the store and the card's size through the
// panel (host.ts). Escape and the panel's cancel do nothing here: only Deny or the panel's native
// Allow ends the ask.
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import { CardOps, useCardSize } from "../host";
import { JoinConsentCard } from "./JoinConsentCard";
import { JoinConsentStore } from "./store";
import { JOIN_CONSENT_CARD } from "./types";

export function JoinConsentCardHost({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [store] = useState(() => new JoinConsentStore(client));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  useIgnoreCancel(client);
  const status = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const ref = useRef<HTMLDivElement | null>(null);
  useCardSize(client, JOIN_CONSENT_CARD, ref);
  return (
    <div ref={ref} className="server-card-frame join-consent-frame">
      <JoinConsentCard status={status} strings={strings} onDeny={() => void store.deny()} />
    </div>
  );
}

/** Listens to the panel's cancel so the panel does not hide the ask itself (WebCardPanel hides a
 * card with no listener), and does nothing with it: Escape neither denies nor closes the ask. */
function useIgnoreCancel(client: PageClient | null): void {
  useEffect(() => {
    let stop: (() => void) | undefined;
    let stopped = false;
    void client
      ?.subscribe(CardOps.commands, () => {})
      .then((unsubscribe) => (stopped ? unsubscribe() : (stop = unsubscribe)))
      .catch(() => {});
    return () => {
      stopped = true;
      stop?.();
    };
  }, [client]);
}
