// The composer's staged files share Undo and Redo with its text (https://github.com/manaflow-ai/cmux/issues/38148).
// The text's edits live in the editor's own history; a file added or removed is not an edit of the
// text, so it goes here, stamped with how many text edits the editor could undo when it happened.
// Cmd-Z then takes the newest of the two: a file edit made after the last text edit comes off
// first, a text edit made after it goes first. Redo walks the same line forward. The editor keeps
// its newest 100 text steps (ProseMirror's history depth): past that, its depth stays at the cap and
// a file edit there can come off before newer text, which only a very long draft reaches.

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
  /// How many of the editor's text redos a file edit ended: the oldest undone text steps, which
  /// its redo stack keeps (ProseMirror has no way to drop only them), but Shift-Cmd-Z must not
  /// bring back.
  private deadTextRedos = 0;

  /// A new file edit: what was undone, files or text (`textRedos`, the editor's redo depth now),
  /// can no longer be redone.
  record(edit: AttachmentEdit<T>, textRedos = 0): void {
    this.undos.push(edit);
    this.redos = [];
    this.deadTextRedos = textRedos;
  }

  /// Whether Shift-Cmd-Z may redo the editor's newest undone text step (`textRedos`, its redo depth
  /// now): not one a file edit ended. Text undone after that edit sits above those and redoes.
  textRedoAllowed(textRedos: number): boolean {
    return textRedos > this.deadTextRedos;
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
    // The editor dropped its redos too.
    this.deadTextRedos = 0;
  }

  /// Files the composer's owner took out itself (a card's files it replaced): no step brings them back,
  /// and a step left with none goes.
  forget(gone: (item: T) => boolean): void {
    const keep = (edits: AttachmentEdit<T>[]) =>
      edits.flatMap((edit) => {
        const items = edit.items.filter((item) => !gone(item));
        if (items.length === edit.items.length) return [edit];
        return items.length ? [{ ...edit, items }] : [];
      });
    this.undos = keep(this.undos);
    this.redos = keep(this.redos);
  }

  /// The files were sent: nothing brings them back.
  clear(): void {
    this.undos = [];
    this.redos = [];
    this.deadTextRedos = 0;
  }
}

/// Cmd-Z (undo), Shift-Cmd-Z or Cmd-Y (redo, as the editor's keymap has them), or neither.
export function undoChord(event: KeyboardEvent): "undo" | "redo" | undefined {
  if (!event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return undefined;
  const key = event.key.toLowerCase();
  if (key === "y" && !event.shiftKey) return "redo";
  if (key !== "z") return undefined;
  return event.shiftKey ? "redo" : "undo";
}
