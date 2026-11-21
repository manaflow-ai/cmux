// Request changes words the page must not lose (QueueScreen.tsx): the open comment box, and a
// comment that reached neither the chat nor the clipboard. They live here, outside History, for
// as long as the pane lives: a tab switch, a chat History opened, or a verdict that settles after
// the page left and came back finds them, and every shown page reads the same copy.
import { useSyncExternalStore } from "react";

export type CommentDraft = { id: string; text: string };
export type CommentsSnapshot = { draft?: CommentDraft; unsent?: string };

export type Comments = {
  get(): CommentsSnapshot;
  subscribe(listener: () => void): () => void;
  /// The open box: which row and what is typed; `undefined` closes it.
  setDraft(draft: CommentDraft | undefined): void;
  /// Opens row `id`'s box: its own words stay; another row's words, if any, are kept beside it.
  open(id: string): void;
  /// Closes row `id`'s box (sent or cancelled); another row's box stays as it is.
  close(id: string): void;
  /// A refused verdict's words come back in their box, unless another comment is being written:
  /// then they are kept beside it, never over it.
  restore(draft: CommentDraft): void;
  /// Words neither the chat nor the clipboard took, after any still kept.
  keepUnsent(text: string): void;
  dismissUnsent(): void;
};

/// Kept words with `text` after them.
function withKept(unsent: string | undefined, text: string): string {
  return unsent ? `${unsent}\n\n${text}` : text;
}

export function createComments(): Comments {
  let snapshot: CommentsSnapshot = {};
  const listeners = new Set<() => void>();
  const set = (next: CommentsSnapshot) => {
    snapshot = next;
    for (const listener of listeners) listener();
  };
  const keepUnsent = (text: string) => set({ ...snapshot, unsent: withKept(snapshot.unsent, text) });
  return {
    get: () => snapshot,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    setDraft: (draft) => set({ ...snapshot, draft }),
    open: (id) => {
      const open = snapshot.draft;
      if (open?.id === id) return;
      const kept = open?.text.trim() ? withKept(snapshot.unsent, open.text) : snapshot.unsent;
      set({ draft: { id, text: "" }, unsent: kept });
    },
    close: (id) => {
      if (snapshot.draft?.id === id) set({ ...snapshot, draft: undefined });
    },
    restore: (draft) => {
      const open = snapshot.draft;
      if (open && open.text.trim() && (open.id !== draft.id || open.text !== draft.text)) keepUnsent(draft.text);
      else set({ ...snapshot, draft });
    },
    keepUnsent,
    dismissUnsent: () => set({ ...snapshot, unsent: undefined }),
  };
}

/// The pane's own copy.
export const paneComments = createComments();

export function useComments(comments: Comments): CommentsSnapshot {
  return useSyncExternalStore(comments.subscribe, comments.get, comments.get);
}
