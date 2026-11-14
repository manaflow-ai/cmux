// The Pair Another Machine card on its route (`#/pair-invite`): the host's status through the
// store, the countdown's one-second tick while an unused invite shows (and only then), and the
// card's size and close through the panel (host.ts).
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import { closeCard, useCardCancel, useCardSize } from "../host";
import { phaseOf, type Action } from "./model";
import { PairInviteCard } from "./PairInviteCard";
import { PairInviteStore } from "./store";
import { PAIR_INVITE_CARD } from "./types";

export function PairInviteCardHost({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [store] = useState(() => new PairInviteStore(client));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  const { status, copied } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [now, setNow] = useState(() => Date.now());
  const waiting = status ? phaseOf(status, now).kind === "waiting" : false;
  useEffect(() => {
    // The countdown changes every second while an unused invite shows; it stops at expiry, on
    // arrival, at the invite's end and when the card closes (the status leaves `waiting`).
    if (!waiting) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [waiting, status?.session]);
  const ref = useRef<HTMLDivElement | null>(null);
  useCardSize(client, PAIR_INVITE_CARD, ref);
  const close = () => closeCard(client, PAIR_INVITE_CARD);
  useCardCancel(client, close);
  const onAction = (action: Action) => {
    switch (action) {
      case "copyCode":
        return void store.copy("code");
      case "copyLine":
        return void store.copy("line");
      case "copyInstallLine":
        return void store.copy("installLine");
      case "confirm":
      case "retry":
        return; // The panel's native button (WebCardPanel's PersonControl), never the page.
      case "newCode":
        return void store.newCode();
      case "done":
      case "cancel":
        return close();
    }
  };
  return (
    <div ref={ref} className="server-card-frame">
      <PairInviteCard
        key={status?.session ?? 0}
        status={status}
        strings={strings}
        now={now}
        copied={copied}
        onAction={onAction}
        onRunChief={(on) => void store.setRunChief(on)}
        onNameChange={(name) => void store.setName(name)}
      />
    </div>
  );
}
