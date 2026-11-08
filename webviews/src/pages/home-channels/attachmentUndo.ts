// The composer's staged files share Undo and Redo with its text (https://github.com/manaflow-ai/cmux/issues/38148).
// The text's edits live in the editor's own history; a file added or removed is not an edit of the
// text, so it goes here, stamped with how many text edits the editor could undo when it happened.
// Cmd-Z then takes the newest of the two: a file edit made after the last text edit comes off
// first, a text edit made after it goes first. Redo walks the same line forward.

export type AttachmentEdit<T> = {
  kind: "add" | "remove";
  items: readonly T[];
  /// Where a removed file sat in the tray, so an undo puts it back there.
  index: number;
  /// The editor's undo depth when the edit was made.
  depth: number;
};

export class AttachmentUndo<T> {
  private undos: AttachmentEdit<T>[] = [];
  private redos: AttachmentEdit<T>[] = [];

  /// A new file edit: what was undone can no longer be redone.
  record(edit: AttachmentEdit<T>): void {
    this.undos.push(edit);
    this.redos = [];
  }

  /// The file edit Cmd-Z undoes now, when no text edit came after it (`textDepth`, the editor's undo
  /// depth now); undefined leaves Cmd-Z to the text.
  takeUndo(textDepth: number): AttachmentEdit<T> | undefined {
    const top = this.undos.at(-1);
    if (!top || top.depth < textDepth) return undefined;
    this.undos.pop();
    this.redos.push(top);
    return top;
  }

  /// The file edit Shift-Cmd-Z redoes now, once the text is back where it was when the edit was
  /// made; undefined leaves Shift-Cmd-Z to the text.
  takeRedo(textDepth: number): AttachmentEdit<T> | undefined {
    const top = this.redos.at(-1);
    if (!top || top.depth > textDepth) return undefined;
    this.redos.pop();
    this.undos.push(top);
    return top;
  }

  /// The person edited the text (not an undo or redo): the file edits undone are gone for good, as
  /// the editor's redo is.
  textEdited(): void {
    this.redos = [];
  }

  /// The files were sent: nothing brings them back.
  clear(): void {
    this.undos = [];
    this.redos = [];
  }
}

/// Cmd-Z (undo), Shift-Cmd-Z (redo), or neither.
export function undoChord(event: KeyboardEvent): "undo" | "redo" | undefined {
  if (!event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return undefined;
  if (event.key.toLowerCase() !== "z") return undefined;
  return event.shiftKey ? "redo" : "undo";
}
