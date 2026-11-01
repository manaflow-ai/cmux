// The code editor's find (Cmd-F): the state behind the shared find pill (ui/FindPill.tsx), which
// replaces Monaco's own find widget so the editor's find looks and acts like every other pane's
// (Lawrence, 2026-10-20). The search runs on the document through a `FindTarget` (view.ts
// implements it over Monaco's model; tests pass a fake), and this class owns the query, the
// matches, the active one and when the pill shows. React reads it through subscribe/getState.

/** How many matches the pill collects and decorates; Replace All still replaces every one. */
export const MATCH_LIMIT = 10_000;

/** One match, in Monaco's 1-based line and column terms. */
export interface FindRange {
  startLineNumber: number;
  startColumn: number;
  endLineNumber: number;
  endColumn: number;
}

/** What find needs from the editor. */
export interface FindTarget {
  /**
   * The matches of `query` in the document, in order (literal text, not a pattern): the first
   * `MATCH_LIMIT` for the pill (so a huge file cannot freeze every keystroke), or all of them with
   * `all`, which only Replace All asks for.
   */
  findMatches(query: string, matchCase: boolean, all?: boolean): FindRange[];
  /**
   * Where the search starts: the start of the selection (the caret when nothing is selected), so
   * the match the pill selected stays the first candidate as the query grows a letter at a time.
   */
  caret(): { lineNumber: number; column: number };
  /** The selected text (one line), or empty. */
  selectedText(): string;
  /** Selects `active` and reveals it; paints every match, or clears them all for an empty list. */
  show(matches: readonly FindRange[], active: number): void;
  /** Gives the keyboard back to the editor. */
  focus(): void;
  /** The document cannot change (no replace row). Absent: editable. */
  readOnly?(): boolean;
  /** Writes `text` over every range as one undo step. Absent: replace is unavailable. */
  replace?(ranges: readonly FindRange[], text: string): void;
}

export interface EditorFindState {
  open: boolean;
  query: string;
  matchCase: boolean;
  matches: readonly FindRange[];
  /** Index into `matches`; 0 when there are none. */
  active: number;
  /** Increments each time the field should take the keyboard with its text selected. */
  focusRequest: number;
  /** The replace row shows (Replace, Opt-Cmd-F). */
  replaceOpen: boolean;
  /** The replace field's text. Kept after the pill closes. */
  replacement: string;
}

const CLOSED: EditorFindState = {
  open: false,
  query: "",
  matchCase: false,
  matches: [],
  active: 0,
  focusRequest: 0,
  replaceOpen: false,
  replacement: "",
};

const before = (a: FindRange, line: number, column: number) =>
  a.startLineNumber < line || (a.startLineNumber === line && a.startColumn < column);

export class EditorFind {
  private state: EditorFindState = CLOSED;
  private target: FindTarget | null = null;
  private readonly listeners = new Set<() => void>();

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getState = () => this.state;

  /** The editor to search, or null while none is mounted (the pill closes). */
  attach(target: FindTarget | null): void {
    this.target = target;
    if (!target && this.state.open) this.set({ ...this.state, open: false, matches: [], active: 0 });
  }

  /** Cmd-F: shows the pill with the field focused; `seed` (a CLI argument) replaces the query. */
  show(seed?: string): void {
    const query = seed ? seed : this.state.query;
    this.search({ ...this.state, open: true, query, focusRequest: this.state.focusRequest + 1 }, true);
  }

  /** Replace (Opt-Cmd-F): the pill with its replace row; a read-only file gets the find row only. */
  showReplace(seed?: string): void {
    const replaceOpen = this.canReplace();
    const query = seed ? seed : this.state.query;
    this.search({ ...this.state, open: true, query, replaceOpen, focusRequest: this.state.focusRequest + 1 }, true);
  }

  setReplacement = (replacement: string) => {
    if (replacement !== this.state.replacement) this.set({ ...this.state, replacement });
  };

  /** The pill's chevron: shows or hides the replace row. */
  toggleReplace = () => {
    if (this.state.replaceOpen) this.set({ ...this.state, replaceOpen: false });
    else if (this.canReplace()) this.set({ ...this.state, replaceOpen: true });
  };

  /** Writes the replacement over the active match, then the next match is active. */
  replace = () => {
    const match = this.state.matches[this.state.active];
    if (!match || !this.canReplace() || !this.state.replaceOpen) return;
    this.target?.replace?.([match], this.state.replacement);
    // The next match is the first one after the text just written: a replacement that contains
    // the query would otherwise be found again in the same place, and Replace never moved on.
    const lines = this.state.replacement.split("\n");
    const written = {
      lineNumber: match.startLineNumber + lines.length - 1,
      column: (lines.length === 1 ? match.startColumn : 1) + lines[lines.length - 1]!.length,
    };
    this.search(this.state, written);
  };

  /** Writes the replacement over every match, as one undo step. */
  replaceAll = () => {
    if (!this.state.matches.length || !this.canReplace() || !this.state.replaceOpen) return;
    // The pill may hold only the first MATCH_LIMIT: the rest are found again for the replace.
    const every = this.target?.findMatches(this.state.query, this.state.matchCase, true) ?? this.state.matches;
    this.target?.replace?.(every, this.state.replacement);
    this.search({ ...this.state, active: 0 }, false);
  };

  private canReplace(): boolean {
    return Boolean(this.target?.replace) && !this.target?.readOnly?.();
  }

  /** Use Selection for Find (Cmd-E): the selection becomes the query. */
  useSelection(): void {
    const text = this.target?.selectedText() ?? "";
    if (text) this.show(text);
  }

  setQuery = (query: string) => {
    if (query !== this.state.query) this.search({ ...this.state, query }, true);
  };

  setMatchCase = (matchCase: boolean) => {
    if (matchCase !== this.state.matchCase) this.search({ ...this.state, matchCase }, true);
  };

  next = () => this.step(1);
  previous = () => this.step(-1);

  /** Escape or the close button: highlights go and the editor gets the keyboard back. */
  hide = () => {
    if (!this.state.open) return;
    this.set({ ...this.state, open: false, replaceOpen: false, matches: [], active: 0 });
    this.target?.show([], 0);
    this.target?.focus();
  };

  /** The document changed: search it again, keeping the active match's place. */
  refresh(): void {
    if (this.state.open) this.search(this.state, false);
  }

  private step(direction: 1 | -1): void {
    // Find Next with the pill closed (Cmd-G) opens it with the last query.
    if (!this.state.open) return this.show();
    const count = this.state.matches.length;
    if (!count) return;
    const active = (this.state.active + direction + count) % count;
    this.set({ ...this.state, active });
    this.target?.show(this.state.matches, active);
  }

  /** `from`: true starts at the caret; a position starts there; false keeps the active index. */
  private search(next: EditorFindState, from: boolean | { lineNumber: number; column: number }): void {
    const matches = next.open && next.query && this.target ? this.target.findMatches(next.query, next.matchCase) : [];
    let active = 0;
    if (matches.length) {
      const start = from === true ? this.target?.caret() : from === false ? undefined : from;
      if (start) {
        const { lineNumber, column } = start;
        const at = matches.findIndex((match) => !before(match, lineNumber, column));
        active = at < 0 ? 0 : at;
      } else {
        active = Math.min(next.active, matches.length - 1);
      }
    }
    this.set({ ...next, matches, active });
    if (next.open) this.target?.show(matches, active);
  }

  private set(state: EditorFindState): void {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
