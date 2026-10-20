// The code editor's find (Cmd-F): the state behind the shared find pill (ui/FindPill.tsx), which
// replaces Monaco's own find widget so the editor's find looks and acts like every other pane's
// (Lawrence, 2026-10-20). The search runs on the document through a `FindTarget` (view.ts
// implements it over Monaco's model; tests pass a fake), and this class owns the query, the
// matches, the active one and when the pill shows. React reads it through subscribe/getState.

/** One match, in Monaco's 1-based line and column terms. */
export interface FindRange {
  startLineNumber: number;
  startColumn: number;
  endLineNumber: number;
  endColumn: number;
}

/** What find needs from the editor. */
export interface FindTarget {
  /** Every match of `query` in the document, in order (literal text, not a pattern). */
  findMatches(query: string, matchCase: boolean): FindRange[];
  /** The caret, to start from the first match at or after it. */
  caret(): { lineNumber: number; column: number };
  /** The selected text (one line), or empty. */
  selectedText(): string;
  /** Selects `active` and reveals it; paints every match, or clears them all for an empty list. */
  show(matches: readonly FindRange[], active: number): void;
  /** Gives the keyboard back to the editor. */
  focus(): void;
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
}

const CLOSED: EditorFindState = { open: false, query: "", matchCase: false, matches: [], active: 0, focusRequest: 0 };

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
    this.set({ ...this.state, open: false, matches: [], active: 0 });
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

  private search(next: EditorFindState, fromCaret: boolean): void {
    const matches = next.open && next.query && this.target ? this.target.findMatches(next.query, next.matchCase) : [];
    let active = 0;
    if (matches.length) {
      if (fromCaret && this.target) {
        const { lineNumber, column } = this.target.caret();
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
