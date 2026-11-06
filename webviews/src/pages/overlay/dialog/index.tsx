// The overlay page's dialog route (`#/dialog`): one cmux dialog, or nothing between dialogs.
import { useCallback, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import type { PageClient } from "../../shared/pageClient";
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
      onEdit={(values) => store.edit(dialog.id, values)}
      onPress={(button, values) => store.press(dialog.id, button, values)}
      onLayout={onLayout}
    />
  );
}

export function mountDialog(root: HTMLElement, client: PageClient): DialogStore {
  const store = new DialogStore(client);
  createRoot(root).render(<DialogRoute store={store} />);
  void store.start();
  return store;
}
