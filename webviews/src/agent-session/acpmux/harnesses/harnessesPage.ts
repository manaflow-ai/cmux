// Opens the pane's Harnesses page from a control the pane does not own (the model picker's +).
// The pane registers the one opener while it is mounted.
let opener: (() => void) | undefined;

/// Registers `open`; returns the unregister function.
export function registerHarnessesPage(open: () => void): () => void {
  opener = open;
  return () => {
    if (opener === open) opener = undefined;
  };
}

/// Shows the Harnesses page; false when no pane is mounted.
export function openHarnessesPage(): boolean {
  opener?.();
  return opener !== undefined;
}
