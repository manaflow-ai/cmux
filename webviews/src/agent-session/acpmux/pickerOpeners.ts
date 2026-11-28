// The composer's menus by their label ("Model", "Mode", ...), so automation opens one
// through the same path as a click: the DEBUG `debug.agent_pane` socket method
// (cmuxAcpmuxDebug.openMenu) and the capture scripts. A scripted pointer click can be
// cancelled by the window focus changes it causes; this cannot.
import { createContext } from "react";

/// True inside a chat view parked under a New Tab page (App.tsx `parked`: drawn but unseen and
/// inert, its effects run so a chat the page takes only shows it). Its menus register no opener and
/// its keys stay off: the page's own composer menus, under the same labels, are the ones to open.
export const ChatViewParked = createContext(false);

const openers = new Map<string, () => void>();

/// Registers `open` under `label`; returns the unregister function.
export function registerPicker(label: string, open: () => void): () => void {
  openers.set(label, open);
  return () => {
    if (openers.get(label) === open) openers.delete(label);
  };
}

/// Opens the menu labelled `label`; false when none is mounted.
export function openPicker(label: string): boolean {
  const open = openers.get(label);
  open?.();
  return open !== undefined;
}

/// The labels of the mounted menus.
export function pickerLabels(): string[] {
  return [...openers.keys()];
}

type ModelCommand = (query: string) => true | string | undefined;
let modelCommand: ModelCommand | undefined;

/// The mounted model picker handles a typed combo using this pane's catalog and session.
export function registerModelCommand(run: ModelCommand): () => void {
  modelCommand = run;
  return () => {
    if (modelCommand === run) modelCommand = undefined;
  };
}

export function runModelCommand(query: string): ReturnType<ModelCommand> {
  return modelCommand?.(query);
}
