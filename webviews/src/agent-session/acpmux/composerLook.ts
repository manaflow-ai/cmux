import { useContext, useSyncExternalStore } from "react";
import { OnNewTab } from "./newTabComposer";

export type ComposerLook = "claude" | "codex";

const defaultLook: ComposerLook = "claude";
let previewLook: ComposerLook = defaultLook;
const listeners = new Set<() => void>();

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function current(): ComposerLook {
  return previewLook;
}

/// Stages a layout in a gallery fixture or browser harness.
export function setPreviewComposerLook(look: ComposerLook = defaultLook) {
  if (look === previewLook) return;
  previewLook = look;
  for (const listener of listeners) listener();
}

export function useComposerLook(): ComposerLook {
  const onNewTab = useContext(OnNewTab);
  const look = useSyncExternalStore(subscribe, current, current);
  return onNewTab ? defaultLook : look;
}
