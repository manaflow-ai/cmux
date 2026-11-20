// The composer's draft and caret, kept outside React state (Composer.tsx). A key the field already
// shows changes nothing else the composer draws (most letters), so it renders nothing; the handlers
// read and write the draft here at once. A render reads it with useSyncExternalStore, so whatever
// makes the composer render (a key that changes what it draws, an attachment, a turn) draws the
// newest draft, never one a skipped key left behind.

/// The draft as the composer holds it now: its markdown and the caret's offset in it.
export type DraftNow = { readonly text: string; readonly caret: number };

export type DraftStore = {
  /// The draft now. The same object until `set` or `draw` changes it (useSyncExternalStore's snapshot).
  now(): DraftNow;
  /// The draft is `text`, the caret at `caret`. Renders nothing by itself.
  set(text: string, caret: number): void;
  /// The composer renders with the draft as it is now.
  draw(): void;
  subscribe(listener: () => void): () => void;
};

export function createDraftStore(text: string): DraftStore {
  let current: DraftNow = { text, caret: 0 };
  const listeners = new Set<() => void>();
  return {
    now: () => current,
    set(next, caret) {
      if (next !== current.text || caret !== current.caret) current = { text: next, caret };
    },
    draw() {
      // A new snapshot even when the draft is the same: the render it asks for always runs (a value
      // or caret put back from outside, which the field takes from that render).
      current = { ...current };
      for (const listener of listeners) listener();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
