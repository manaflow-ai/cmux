// The composer's menus by their label ("Model", "Mode", ...), so automation opens one
// through the same path as a click: the DEBUG `debug.agent_pane` socket method
// (cmuxAcpmuxDebug.openMenu) and the capture scripts. A scripted pointer click can be
// cancelled by the window focus changes it causes; this cannot.
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
