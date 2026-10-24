import type { AcpmuxRow } from "../model";

export type BtwNote = {
  id: string;
  sessionId: string;
  question: string;
  at: number;
  anchorId?: string;
  answer?: string;
  error?: string;
};
export type BtwRow = AcpmuxRow & { btw: BtwNote; dismissBtw(): void };
type Ask = (question: string, sessionId: string) => Promise<string>;

/// UI-only asides never join the agent's transcript, prompt history, queue or turn reducer.
/// A late answer belongs to its original chat and cannot resurrect a dismissed note.
export class BtwNotes {
  private notes: readonly BtwNote[] = [];
  private listeners = new Set<() => void>();
  private rendered = new WeakMap<BtwNote, BtwRow>();
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  snapshot = () => this.notes;

  ask(sessionId: string, question: string, anchor: AcpmuxRow | undefined, ask: Ask): void {
    const note: BtwNote = {
      id: `btw-${crypto.randomUUID()}`,
      sessionId,
      question,
      at: Date.now(),
      anchorId: anchor?.id,
    };
    this.set([...this.notes, note]);
    // No side effect is deferred past a chat switch: ask captures and validates its source id.
    Promise.resolve()
      .then(() => ask(question, sessionId))
      .then(
        (answer) => this.finish(note.id, { answer }),
        (failure: unknown) => this.finish(note.id, { error: failure instanceof Error ? failure.message : "" }),
      );
  }

  dismiss = (id: string): void => {
    this.set(this.notes.filter((note) => note.id !== id));
  };

  rows(rows: AcpmuxRow[], sessionId: string | undefined, snapshot = this.notes): AcpmuxRow[] {
    const notes = snapshot.filter((note) => note.sessionId === sessionId);
    if (!notes.length) return rows;
    const result = [...rows];
    for (const note of notes) {
      let row = this.rendered.get(note);
      if (!row) {
        row = {
          id: note.id,
          kind: "btw",
          at: note.at,
          version: note.answer !== undefined || note.error !== undefined ? 2 : 1,
          text: note.answer,
          btw: note,
          dismissBtw: () => this.dismiss(note.id),
        };
        this.rendered.set(note, row);
      }
      const anchor = result.findIndex((entry) => entry.id === note.anchorId);
      // A collapsed/finished turn can remove the anchor: retain the ask's place by time.
      let at = anchor < 0 ? result.findIndex((entry) => entry.at > note.at) : anchor + 1;
      if (at < 0) at = result.length;
      while (at < result.length && result[at].kind === "btw" && result[at].at <= note.at) at++;
      result.splice(at, 0, row);
    }
    return result;
  }

  private finish(id: string, result: Pick<BtwNote, "answer" | "error">): void {
    if (!this.notes.some((note) => note.id === id)) return;
    this.set(this.notes.map((note) => (note.id === id ? { ...note, ...result } : note)));
  }
  private set(notes: readonly BtwNote[]): void {
    this.notes = notes;
    for (const listener of this.listeners) listener();
  }
}
