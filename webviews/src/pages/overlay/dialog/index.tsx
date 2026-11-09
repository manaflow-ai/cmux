// The overlay page's dialog route (`#/dialog`): one cmux dialog, or nothing between dialogs.
import { useCallback, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import type { PageClient } from "../../shared/pageClient";
import { setDocumentLanguage } from "../../shared/i18n";
import { languageDirection, UiProvider } from "../../../ui/UiProvider";
import { DialogStore } from "./dialogStore";
import { OverlayDialog } from "./OverlayDialog";
import "./dialog.css";

function DialogRoute({ store }: { store: DialogStore }) {
  const dialog = useSyncExternalStore(store.subscribe, store.snapshot);
  const id = dialog?.id ?? 0;
  const onLayout = useCallback(
    (card: { x: number; y: number; w: number; h: number }) => store.layout(id, card),
    [store, id],
  );
  if (!dialog) return null;
  return (
    <OverlayDialog
      key={dialog.id}
      dialog={dialog}
      onEdit={(values) => store.edit(dialog.id, dialog.valuesSerial ?? 0, values)}
      onPress={(button, values) => store.press(dialog.id, dialog.valuesSerial ?? 0, button, values)}
      onLayout={onLayout}
      onPainted={() => store.painted(dialog.id)}
    />
  );
}

export function mountDialog(root: HTMLElement, client: PageClient): DialogStore {
  const store = new DialogStore(client);
  // The dialog's words come from the app in its language: the card follows that language's direction
  // (button order, alignment), and its popup portals into the page's root.
  const language = navigator.language || "en";
  setDocumentLanguage(language);
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(language)}>
      <DialogRoute store={store} />
    </UiProvider>,
  );
  void store.start();
  return store;
}
