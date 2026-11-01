// Settings > Appearance's undo stack. Every appearance change (a row, the background picker, a
// theme level, a preset, a reset) is one entry of before and after states; Undo puts the before
// states back, Redo the after states. The stack is page state, never written to cmux.json: it
// lasts while the Settings page is open. A step applies only while its targets still show what
// the step left (Undo) or found (Redo); after another writer changed one, the step is dropped. A pure model, so the stack and its labels are tested
// without a page.

/** One setting's state: `customized` false means unset (the default), whatever `value` says. */
export type KeyState = { kind: "setting"; key: string; value: unknown; customized: boolean };
/** One theme level of the active window (`cmux.settings.theme.set`); null spec is the Ghostty config. */
export type ThemeState = { kind: "theme"; level: string; spec: string | null };
export type TargetState = KeyState | ThemeState;

/** One target before and after a change. */
export type Change = { before: TargetState; after: TargetState };

/** One undoable step: what the buttons' tooltips name ("Wallpaper → Shuffle Paintings"). */
export type HistoryEntry = { label: string; changes: Change[] };

/** The identity of a target, so two states of one target compare. */
export function targetId(state: TargetState): string {
  return state.kind === "setting" ? `setting:${state.key}` : `theme:${state.level}`;
}

/** Whether two states of one target show the same thing. */
export function sameState(a: TargetState, b: TargetState): boolean {
  if (a.kind === "setting" && b.kind === "setting") {
    if (!a.customized && !b.customized) return true;
    return a.customized === b.customized && JSON.stringify(a.value) === JSON.stringify(b.value);
  }
  if (a.kind === "theme" && b.kind === "theme") return a.spec === b.spec;
  return false;
}

/** The changes between two state lists of the same targets, in `before`'s order; unchanged
 * targets are left out. */
export function diff(before: readonly TargetState[], after: readonly TargetState[]): Change[] {
  const next = new Map(after.map((state) => [targetId(state), state]));
  const changes: Change[] = [];
  for (const state of before) {
    const other = next.get(targetId(state));
    if (other && !sameState(state, other)) changes.push({ before: state, after: other });
  }
  return changes;
}

/** How many steps Undo keeps. */
export const HISTORY_LIMIT = 100;

export class AppearanceHistory {
  private undoStack: HistoryEntry[] = [];
  private redoStack: HistoryEntry[] = [];
  private listeners = new Set<() => void>();
  /** Bumped on every change, for useSyncExternalStore. */
  version = 0;

  /** Records a step; a step with no change is dropped. A new step clears Redo. */
  record(entry: HistoryEntry): boolean {
    if (entry.changes.length === 0) return false;
    this.undoStack.push(entry);
    if (this.undoStack.length > HISTORY_LIMIT) this.undoStack.shift();
    this.redoStack = [];
    this.emit();
    return true;
  }

  get canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  get canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  /** The step Undo would take back. */
  get nextUndo(): HistoryEntry | null {
    return this.undoStack[this.undoStack.length - 1] ?? null;
  }

  /** The step Redo would put back. */
  get nextRedo(): HistoryEntry | null {
    return this.redoStack[this.redoStack.length - 1] ?? null;
  }

  /** Takes the last step for undoing: the states to apply are its changes' `before`, last first. */
  takeUndo(): { entry: HistoryEntry; apply: TargetState[] } | null {
    const entry = this.undoStack.pop();
    if (!entry) return null;
    this.redoStack.push(entry);
    this.emit();
    return { entry, apply: [...entry.changes].reverse().map((change) => change.before) };
  }

  /** Takes the last undone step for redoing: the states to apply are its changes' `after`. */
  takeRedo(): { entry: HistoryEntry; apply: TargetState[] } | null {
    const entry = this.redoStack.pop();
    if (!entry) return null;
    this.undoStack.push(entry);
    this.emit();
    return { entry, apply: entry.changes.map((change) => change.after) };
  }

  /** Drops the step Undo or Redo would take next without applying it: one whose targets another
   * writer has changed since (#29881), so putting its states back would overwrite that change. */
  discard(direction: "undo" | "redo"): void {
    const stack = direction === "undo" ? this.undoStack : this.redoStack;
    if (stack.pop()) this.emit();
  }

  /** Puts a step back where it was when applying it failed (nothing changed). */
  restore(direction: "undo" | "redo", entry: HistoryEntry): void {
    const [from, to] = direction === "undo" ? [this.redoStack, this.undoStack] : [this.undoStack, this.redoStack];
    const index = from.lastIndexOf(entry);
    if (index >= 0) from.splice(index, 1);
    to.push(entry);
    this.emit();
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}
