// The Add Machine card on its route (`#/add-machine`): the host's runs through the store, the
// card's size and close through the panel (host.ts), Escape and Return as the card's keyed buttons.
import { useEffect, useRef, useState } from "react";
import type { PageClient } from "../../shared/pageClient";
import type { Strings } from "../../shared/i18n";
import { isImeKeyEvent } from "../../shared/imeKeys";
import { closeCard, useCardCancel, useCardSize } from "../host";
import { AddMachineCard } from "./AddMachineCard";
import { AddMachineStore } from "./store";
import { ADD_MACHINE_CARD } from "./types";

export function AddMachineCardHost({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const [store] = useState(() => new AddMachineStore(client, () => closeCard(client, ADD_MACHINE_CARD)));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  const ref = useRef<HTMLDivElement | null>(null);
  useCardSize(client, ADD_MACHINE_CARD, ref);
  useCardCancel(client, () => void store.escape());
  useEffect(() => {
    // Return presses the card's Return button from anywhere in the card but a focused button
    // (which presses itself) or an IME composition.
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Enter" || event.defaultPrevented || isImeKeyEvent(event)) return;
      if (event.target instanceof HTMLButtonElement) return;
      event.preventDefault();
      void store.submit();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [store]);
  return (
    <div ref={ref} className="server-card-frame">
      <AddMachineCard store={store} strings={strings} />
    </div>
  );
}
