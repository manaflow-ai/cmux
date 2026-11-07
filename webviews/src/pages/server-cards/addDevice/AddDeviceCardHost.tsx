// The Add Device card on its route (`#/add-device`): the model through the store, the card's size
// and close through the panel (host.ts), and one list read when the panel gets the focus back while
// a join line shows (the person came back from the new machine's terminal). Nothing polls.
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import { closeCard, useCardCancel, useCardSize } from "../host";
import { AddDeviceCard } from "./AddDeviceCard";
import type { AddDeviceAction } from "./model";
import { AddDeviceStore } from "./store";
import { ADD_DEVICE_CARD } from "./types";

/** Hand-offs the host carries out itself: another card takes the panel, or the host hides it. */
const HAND_OFFS = new Set<AddDeviceAction["kind"]>([
  "pick",
  "otherComputer",
  "newCloudMachine",
  "enterCode",
  "signIn",
  "showMachines",
  "pairAnotherMachine",
]);

export function AddDeviceCardHost({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [store] = useState(() => new AddDeviceStore(client));
  useEffect(() => {
    void store.start();
    const onFocus = () => store.focused();
    window.addEventListener("focus", onFocus);
    return () => {
      window.removeEventListener("focus", onFocus);
      store.stop();
    };
  }, [store]);
  const model = store.model;
  const state = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const ref = useRef<HTMLDivElement | null>(null);
  useCardSize(client, ADD_DEVICE_CARD, ref);
  const onAction = (action: AddDeviceAction) => {
    const closes = model.perform(action);
    // A hand-off's own op moves the panel on (another card, or hidden); Cancel and Done close it here.
    if (closes && !HAND_OFFS.has(action.kind)) closeCard(client, ADD_DEVICE_CARD);
  };
  useCardCancel(client, () => onAction({ kind: "cancel" }));
  return (
    <div ref={ref} className="server-card-frame add-device-frame">
      <AddDeviceCard model={model} state={state} strings={strings} onAction={onAction} />
    </div>
  );
}
