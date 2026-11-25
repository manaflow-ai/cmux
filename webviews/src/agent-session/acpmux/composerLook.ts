// The composer's look. `claude` is the one look a chat draws by default (the model and access in the
// quiet row under the box); `codex` is the former in-box row, staged only by gallery previews and the
// composer refresh (composerV2.ts). `studio` is opt-in, set only by Settings (`agentPane.composerLook`
// "studio", composerSettings.ts): the in-box row laid out as a coding studio's composer draws it, the
// model, effort and access chips on the row's left, the attach paperclip and a round accent Send on
// its right (composerLook.css `data-composer-variant="studio"`). The New Tab page keeps Claude's.
import { useContext, useSyncExternalStore } from "react";
import { composerSettingsSnapshot, subscribeComposerSettings } from "./composerSettings";
import { OnNewTab } from "./newTabComposer";

export type ComposerLook = "claude" | "codex" | "studio";

/// Whether `look` draws the mode, model and effort row inside the box (Codex's and Studio's).
export function lookRowInBox(look: ComposerLook): boolean {
  return look !== "claude";
}

const defaultLook: ComposerLook = "claude";
/// A gallery fixture's or browser harness's staged look, over Settings'.
let previewLook: ComposerLook | undefined;
const listeners = new Set<() => void>();

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Settings' look (agentPane.composerLook) arrives on the host's `composer` event.
  const offSettings = subscribeComposerSettings(listener);
  return () => {
    listeners.delete(listener);
    offSettings();
  };
}

/// The look Settings sets (`agentPane.composerLook`): only "studio" draws another look; "auto"
/// keeps the app's own.
function settingLook(): ComposerLook | undefined {
  return composerSettingsSnapshot().composerLook === "studio" ? "studio" : undefined;
}

function current(): ComposerLook {
  return previewLook ?? settingLook() ?? defaultLook;
}

/// Stages a layout in a gallery fixture or browser harness; with no look, Settings' (else Claude's)
/// is back.
export function setPreviewComposerLook(look?: ComposerLook) {
  if (look === previewLook) return;
  previewLook = look;
  for (const listener of listeners) listener();
}

export function useComposerLook(): ComposerLook {
  const onNewTab = useContext(OnNewTab);
  const look = useSyncExternalStore(subscribe, current, current);
  return onNewTab ? defaultLook : look;
}
