/**
 * Bounded page-side state for the session-list driver (row 7d).
 *
 * Rust owns list membership, continuation, credit and question ids. This store only retains the
 * rows and question results the page has been given, with a bounded projection for each slot.
 */

export type SessionListRow = { sessionId: string; [key: string]: unknown };
export type SessionListKey = { origin: string; chatId: string };
export type SessionListOrigin = { origin: string; state: string };
export type SessionListQuestion = {
  id: string;
  kind: string;
  rows: readonly SessionListRow[];
  hasBefore: boolean;
  hasAfter: boolean;
  complete: boolean;
  coldUnread: boolean;
  deeper: readonly SessionListKey[];
  missing: readonly SessionListKey[];
  unknown: readonly SessionListKey[];
};

export type SessionListSnapshot = {
  readonly sid: string;
  readonly slots: ReadonlyMap<string, readonly SessionListRow[]>;
  readonly questions: ReadonlyMap<string, SessionListQuestion>;
  readonly origins: ReadonlyMap<string, SessionListOrigin>;
  readonly ready: boolean;
  readonly off?: string;
};

export type SessionListBatch = { batch: number; changes: readonly unknown[] };

export type SessionListChange =
  | {
      kind: "rows";
      sid: string;
      slot: string;
      upserts: readonly SessionListRow[];
      remove: readonly SessionListKey[];
      complete: boolean;
    }
  | {
      kind: "page";
      sid: string;
      id: string;
      rows: readonly SessionListRow[];
      hasBefore: boolean;
      hasAfter: boolean;
      complete: boolean;
      coldUnread: boolean;
      deeper: readonly SessionListKey[];
      missing: readonly SessionListKey[];
      unknown: readonly SessionListKey[];
    }
  | { kind: "origin"; sid: string; origin: string; state: string }
  | { kind: "off"; sid?: string; code: string }
  | { kind: "error"; sid?: string; code: string };

export const LIST_MAX_ROWS = 200;
export const LIST_MAX_QUESTIONS = 16;
export const LIST_MAX_WANTS = 4_096;

const EMPTY_ROWS: readonly SessionListRow[] = Object.freeze([]);
const EMPTY_KEYS: readonly SessionListKey[] = Object.freeze([]);

const keyOf = (row: SessionListRow): string =>
  `${typeof row.origin === "string" ? row.origin : "local"}\u0000${row.sessionId}`;
const refOf = (ref: SessionListKey): string => `${ref.origin}\u0000${ref.chatId}`;
const rowRef = (row: SessionListRow): SessionListKey => ({
  origin: typeof row.origin === "string" ? row.origin : "local",
  chatId: row.sessionId,
});

function normalizeRow(value: SessionListRow): SessionListRow | null {
  const id =
    typeof value.sessionId === "string" && value.sessionId
      ? value.sessionId
      : typeof value.chatId === "string" && value.chatId
        ? value.chatId
        : undefined;
  return id ? (typeof value.sessionId === "string" ? value : { ...value, sessionId: id }) : null;
}

class SidList {
  readonly sid: string;
  private slots = new Map<string, Map<string, SessionListRow>>();
  private questions = new Map<string, SessionListQuestion>();
  private origins = new Map<string, SessionListOrigin>();
  private snapshot: SessionListSnapshot;
  private changed = false;
  private ready = false;
  private off: string | undefined;
  private pendingPages = new Map<string, Extract<SessionListChange, { kind: "page" }>>();

  constructor(sid: string) {
    this.sid = sid;
    this.snapshot = this.build();
  }

  get current(): SessionListSnapshot {
    return this.snapshot;
  }

  questionAsked(id: string, kind: string): void {
    const active = [...this.questions.values()].filter((question) => !question.complete).length;
    if (active >= LIST_MAX_QUESTIONS) throw new Error("list.busy");
    if (this.questions.size >= LIST_MAX_QUESTIONS) {
      const oldId = [...this.questions.entries()].find(([, question]) => question.complete)?.[0];
      if (oldId) this.questions.delete(oldId);
    }
    this.questions.set(id, {
      id,
      kind,
      rows: EMPTY_ROWS,
      hasBefore: false,
      hasAfter: false,
      complete: false,
      coldUnread: false,
      deeper: EMPTY_KEYS,
      missing: EMPTY_KEYS,
      unknown: EMPTY_KEYS,
    });
  }

  renameQuestion(from: string, to: string): void {
    if (from === to) return;
    const question = this.questions.get(from);
    if (question) {
      this.questions.delete(from);
      this.questions.set(to, { ...question, id: to });
    }
    const pending = this.pendingPages.get(to);
    if (pending) {
      this.pendingPages.delete(to);
      this.applyPage(pending);
    }
  }

  apply(change: SessionListChange): void {
    if (change.sid && change.sid !== this.sid) return;
    switch (change.kind) {
      case "rows": {
        if (change.upserts.length > LIST_MAX_ROWS) throw new Error("list.rows");
        const slot = this.slots.get(change.slot) ?? new Map<string, SessionListRow>();
        for (const ref of change.remove) slot.delete(refOf(ref));
        for (const row of change.upserts) {
          const normalized = normalizeRow(row);
          if (normalized) slot.set(keyOf(normalized), normalized);
        }
        this.trim(slot);
        this.slots.set(change.slot, slot);
        this.ready = true;
        this.changed = true;
        return;
      }
      case "page": {
        if (change.rows.length > LIST_MAX_ROWS) throw new Error("list.rows");
        const previous = this.questions.get(change.id);
        if (!previous) {
          this.pendingPages.set(change.id, change);
          return;
        }
        this.applyPage(change);
        return;
      }
      case "origin":
        this.origins.set(change.origin, { origin: change.origin, state: change.state });
        this.changed = true;
        return;
      case "off":
        this.off = change.code;
        this.changed = true;
        return;
      case "error":
        if (change.code === "list.page" || change.code === "list.busy") {
          for (const [id, question] of this.questions) {
            if (!question.complete) this.questions.set(id, { ...question, complete: true });
          }
          this.changed = true;
        }
    }
  }

  private applyPage(change: Extract<SessionListChange, { kind: "page" }>): void {
    if (!this.questions.has(change.id)) return;
    const rows = Object.freeze(
      change.rows.flatMap((row) => {
        const normalized = normalizeRow(row);
        return normalized ? [normalized] : [];
      }),
    );
    this.questions.set(change.id, { ...change, rows });
    this.changed = true;
  }

  settle(): SessionListSnapshot | null {
    if (!this.changed) return null;
    this.snapshot = this.build();
    this.changed = false;
    return this.snapshot;
  }

  close(): void {
    this.slots.clear();
    this.questions.clear();
    this.origins.clear();
    this.pendingPages.clear();
    this.snapshot = this.build();
    this.changed = false;
  }

  private trim(slot: Map<string, SessionListRow>): void {
    if (slot.size <= LIST_MAX_ROWS) return;
    const remove = [...slot.keys()].slice(0, slot.size - LIST_MAX_ROWS);
    for (const key of remove) slot.delete(key);
  }

  private build(): SessionListSnapshot {
    const slots = new Map<string, readonly SessionListRow[]>();
    for (const [name, rows] of this.slots)
      slots.set(name, Object.freeze([...rows.values()]) as readonly SessionListRow[]);
    return {
      sid: this.sid,
      slots,
      questions: new Map(this.questions),
      origins: new Map(this.origins),
      ready: this.ready,
      ...(this.off ? { off: this.off } : {}),
    };
  }
}

type Listener = (snapshot: SessionListSnapshot) => void;

export class SessionListStore {
  private sids = new Map<string, SidList>();
  private listeners = new Map<string, Set<Listener>>();

  open(sid: string): void {
    if (!this.sids.has(sid)) this.sids.set(sid, new SidList(sid));
  }

  close(sid: string): void {
    this.sids.delete(sid);
    this.listeners.delete(sid);
  }

  has(sid: string): boolean {
    return this.sids.has(sid);
  }

  snapshot(sid: string): SessionListSnapshot | undefined {
    return this.sids.get(sid)?.current;
  }

  questionAsked(sid: string, id: string, kind: string): void {
    const list = this.sids.get(sid);
    if (!list) throw new Error("list.sid");
    list.questionAsked(id, kind);
  }

  renameQuestion(sid: string, from: string, to: string): void {
    this.sids.get(sid)?.renameQuestion(from, to);
  }

  apply(change: SessionListChange): readonly string[] {
    if (change.sid) {
      const list = this.sids.get(change.sid);
      if (!list) return [];
      list.apply(change);
      return [change.sid];
    }
    const touched: string[] = [];
    for (const [sid, list] of this.sids) {
      list.apply(change);
      touched.push(sid);
    }
    return touched;
  }

  commit(sid: string): void {
    const list = this.sids.get(sid);
    const snapshot = list?.settle();
    if (!snapshot) return;
    for (const listener of this.listeners.get(sid) ?? []) listener(snapshot);
  }

  subscribe(sid: string, listener: Listener): () => void {
    const listeners = this.listeners.get(sid) ?? new Set<Listener>();
    listeners.add(listener);
    this.listeners.set(sid, listeners);
    const snapshot = this.snapshot(sid);
    if (snapshot?.ready) listener(snapshot);
    return () => listeners.delete(listener);
  }
}

export function parseSessionListChange(value: unknown): SessionListChange | null {
  let parsed = value;
  if (typeof value === "string") {
    try {
      parsed = JSON.parse(value);
    } catch {
      return null;
    }
  }
  if (!parsed || typeof parsed !== "object" || typeof (parsed as { kind?: unknown }).kind !== "string") return null;
  const change = parsed as SessionListChange;
  if (typeof (change as { sid?: unknown }).sid !== "string" && change.kind !== "off") return null;
  return change;
}
