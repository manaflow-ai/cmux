// Cmd-Z and Shift-Cmd-Z over a composer's staged files and its text, on one line
// (https://github.com/manaflow-ai/cmux/issues/38148). The Channels composer and Home's Chief composer
// (home-messages MessageComposer) keep their files differently; each says how a file comes out of its
// tray and goes back, and this runs the history (attachmentUndo.ts) between them and the editor's own.
import { useEffect, useRef, type RefObject } from "react";
import type { PromptEditorHandle } from "../../agent-session/acpmux/composer/PromptEditor";
import { AttachmentUndo, undoChord, type AttachmentEdit } from "./attachmentUndo";

export type FileTray<T> = {
  /** Takes `items` out of the tray; an upload still running stops. */
  takeOut(items: readonly T[]): void;
  /** Puts `items` back at `index` as they were; one whose upload was stopped uploads again. */
  putBack(items: readonly T[], index: number): void;
  /** `items` as the tray has them now (a picture or upload that ended after the edit stays with them). */
  current(items: readonly T[]): readonly T[];
};

export type FileUndo<T> = {
  /** A file edit of the person's: undoable, and what they type next is a new text step. `focus` (the
   * default) takes the keyboard back to the field; an add from elsewhere in the app leaves it. */
  noteFileEdit(edit: Omit<AttachmentEdit<T>, "depth">, focus?: boolean): void;
  /** Files the owner took out itself: no undo or redo brings them back. */
  forget(gone: (item: T) => boolean): void;
  /** The editor's key-down: Cmd-Z, Shift-Cmd-Z and Cmd-Y run here (true), other keys do not. */
  keyDown(event: KeyboardEvent): boolean;
  /** The editor reported a change of its text. */
  textChanged(): void;
  /** The composer wrote the text itself (a quote, the clear after a send): a new edit like typing,
   * though the editor reports no change for it. */
  textWritten(): void;
  /** The files were sent, or the editor's history was replaced: nothing brings the old steps back. */
  clear(): void;
};

/** `root` holds the editor: Edit > Undo and Redo reach it as `beforeinput` (historyUndo, historyRedo). */
export function useFileUndo<T>(
  editor: RefObject<PromptEditorHandle | null>,
  root: RefObject<HTMLElement | null>,
  tray: FileTray<T>,
): FileUndo<T> {
  const history = useRef(new AttachmentUndo<T>());
  /// An undo or redo the editor runs on its text: its change is no new edit.
  const replaying = useRef(false);
  const trayNow = useRef(tray);
  trayNow.current = tray;

  /// Cmd-Z or Shift-Cmd-Z on a file edit: an add undone or a remove redone takes the files out, the
  /// others put them back. Returns whether a file edit was the newest.
  const replayFiles = (direction: "undo" | "redo"): boolean => {
    const depth = editor.current?.history().depth ?? 0;
    const edit = direction === "undo" ? history.current.takeUndo(depth) : history.current.takeRedo(depth);
    if (!edit) return false;
    const removes = (edit.kind === "add") === (direction === "undo");
    if (removes) {
      const now = trayNow.current.current(edit.items);
      // Kept as they are now, so a redo brings back the finished upload and its picture.
      Object.assign(edit, { items: now });
      trayNow.current.takeOut(now);
    } else trayNow.current.putBack(edit.items, edit.index);
    return true;
  };
  /// An undo or redo (its key, or Edit > Undo and Redo as `beforeinput`): a file edit that is the
  /// newest runs here; otherwise the editor runs its text's in this same event.
  const replay = (direction: "undo" | "redo", event: Event) => {
    if (replayFiles(direction)) {
      event.preventDefault();
      // The editor's history takes `historyUndo` input too: this one was the files'.
      if (event.type === "beforeinput") event.stopPropagation();
      return;
    }
    // A text step undone before a newer file edit is gone, as typing would have dropped it.
    if (direction === "redo" && !history.current.textRedoAllowed(editor.current?.history().redoDepth ?? 0)) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    replaying.current = true;
    queueMicrotask(() => {
      replaying.current = false;
    });
  };
  const replayRef = useRef(replay);
  replayRef.current = replay;
  useEffect(() => {
    const node = root.current;
    if (!node) return;
    const input = (event: Event) => {
      const type = (event as InputEvent).inputType;
      if (type === "historyUndo" || type === "historyRedo")
        replayRef.current(type === "historyUndo" ? "undo" : "redo", event);
    };
    node.addEventListener("beforeinput", input, true);
    return () => node.removeEventListener("beforeinput", input, true);
  }, [root]);

  return {
    noteFileEdit: (edit, focus = true) => {
      const text = editor.current?.history();
      history.current.record({ ...edit, depth: text?.depth ?? 0 }, text?.redoDepth ?? 0);
      editor.current?.closeHistory();
      // A click on the tray or a file chooser took the keyboard from the field: Cmd-Z goes to it again.
      if (focus) editor.current?.focus();
    },
    forget: (gone) => history.current.forget(gone),
    keyDown: (event) => {
      const chord = undoChord(event);
      if (!chord) return false;
      replay(chord, event);
      return true;
    },
    textChanged: () => {
      if (!replaying.current) history.current.textEdited();
    },
    textWritten: () => history.current.textEdited(),
    clear: () => history.current.clear(),
  };
}
