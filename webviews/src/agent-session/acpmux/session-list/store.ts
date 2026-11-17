/** Page-side projection for the session-list driver (row 7d).
 *
 * The driver owns list membership and continuation. The document keeps one row map keyed by
 * origin/chat id and each sid keeps only membership keys into that map. Rows are never trimmed by
 * insertion order here; a driver over-limit is reported as an error.
 */

export type SessionListRow = { sessionId: string; [key: string]: unknown };
export type SessionListKey = { origin: string; chatId: string };
export type SessionListOrigin = { origin: string; state: string };
export type SessionListQuestionState = "pending" | "complete" | "failed" | "closed";
export type SessionListQuestion = {
  id: string;
  kind: string;
  rows: readonly SessionListRow[];
  hasBefore: boolean;
  hasAfter: boolean;
  complete: boolean;
  state: SessionListQuestionState;
  error?: string;
  coldUnread: boolean;
  deeper: readonly SessionListKey[];
  missing: readonly SessionListKey[];
  unknown: readonly SessionListKey[];
};

export type SessionListSnapshot = {
  readonly sid: string;
  readonly slots: ReadonlyMap<string, readonly SessionListRow[]>;
  readonly slotComplete: ReadonlyMap<string, boolean>;
  readonly questions: ReadonlyMap<string, SessionListQuestion>;
  readonly origins: ReadonlyMap<string, SessionListOrigin>;
  readonly ready: boolean;
  readonly off?: string;
  readonly error?: string;
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
  | { kind: "on"; sid: string }
  | { kind: "origin"; sid: string; origin: string; state: string }
  | { kind: "off"; sid?: string; code: string }
  | { kind: "error"; sid?: string; id?: string; code: string };

export const LIST_MAX_ROWS = 200;
export const LIST_MAX_QUESTIONS = 16;
export const LIST_MAX_WANTS = 4_096;

const EMPTY_ROWS: readonly SessionListRow[] = Object.freeze([]);
const EMPTY_KEYS: readonly SessionListKey[] = Object.freeze([]);

// The driver identifies a row from chatId first, then sessionId. Keep that order here so a
// remove emitted from Rust addresses the same document row even when both fields are present.
const keyOf = (row: SessionListRow): string =>
  `${typeof row.origin === "string" ? row.origin : "local"}\u0000${
    typeof row.chatId === "string" ? row.chatId : row.sessionId
  }`;
const refOf = (ref: SessionListKey): string => `${ref.origin}\u0000${ref.chatId}`;

/** Stable newest-first order shared by the driver projection and page slots. */
export function sessionListOrder(row: SessionListRow): [number, string, string] {
  const activity =
    typeof row.updatedMs === "number" ? row.updatedMs : typeof row.lastActivity === "number" ? row.lastActivity : 0;
  const origin = typeof row.origin === "string" ? row.origin : "local";
  const id = typeof row.chatId === "string" ? row.chatId : row.sessionId;
  return [activity, id, origin];
}

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
  private slots = new Map<string, Map<string, undefined>>();
  private slotComplete = new Map<string, boolean>();
  private questions = new Map<string, SessionListQuestion>();
  private questionOrder = new Map<string, number>();
  private origins = new Map<string, SessionListOrigin>();
  private snapshot: SessionListSnapshot;
  private changed = false;
  private dirtyAll = true;
  private dirtySlots = new Set<string>();
  private dirtyQuestions = new Set<string>();
  private ready = false;
  private off: string | undefined;
  private error: string | undefined;
  private pendingPages = new Map<string, Extract<SessionListChange, { kind: "page" }>>();
  private questionRows = new Map<string, Set<string>>();

  constructor(
    sid: string,
    private readonly rows: Map<string, SessionListRow>,
    private readonly holders: Map<string, number>,
    private readonly nextQuestionOrder: () => number,
  ) {
    this.sid = sid;
    this.snapshot = {
      sid,
      slots: new Map(),
      slotComplete: new Map(),
      questions: new Map(),
      origins: new Map(),
      ready: false,
    };
    this.snapshot = this.build();
  }

  get current(): SessionListSnapshot {
    return this.snapshot;
  }

  questionAsked(id: string, kind: string): void {
    const active = [...this.questions.values()].filter((question) => question.state === "pending").length;
    if (active >= LIST_MAX_QUESTIONS) throw new Error("list.busy");
    if (this.questions.size >= LIST_MAX_QUESTIONS) {
      const evict = [...this.questionOrder.entries()]
        .filter(([questionId]) => this.questions.get(questionId)?.state !== "pending")
        .sort((a, b) => a[1] - b[1])[0]?.[0];
      if (evict) {
        this.releaseQuestionRows(evict);
        this.questions.delete(evict);
        this.questionOrder.delete(evict);
        this.dirtyQuestions.add(evict);
      }
    }
    this.questions.set(id, {
      id,
      kind,
      rows: EMPTY_ROWS,
      hasBefore: false,
      hasAfter: false,
      complete: false,
      state: "pending",
      coldUnread: false,
      deeper: EMPTY_KEYS,
      missing: EMPTY_KEYS,
      unknown: EMPTY_KEYS,
    });
    this.questionOrder.set(id, this.nextQuestionOrder());
    this.dirtyQuestions.add(id);
  }

  renameQuestion(from: string, to: string): void {
    if (from === to) return;
    const question = this.questions.get(from);
    if (question) {
      this.questions.delete(from);
      this.questionOrder.set(to, this.questionOrder.get(from) ?? this.nextQuestionOrder());
      this.questionOrder.delete(from);
      this.questions.set(to, { ...question, id: to });
      this.dirtyQuestions.add(from);
      this.dirtyQuestions.add(to);
    }
    const pending = this.pendingPages.get(from) ?? this.pendingPages.get(to);
    if (pending) {
      this.pendingPages.delete(from);
      this.pendingPages.delete(to);
      this.applyPage({ ...pending, id: to });
    }
  }

  closeQuestion(id: string): boolean {
    const question = this.questions.get(id);
    if (!question) return false;
    if (question.state === "pending") {
      this.questions.set(id, { ...question, state: "closed", complete: false });
      this.releaseQuestionRows(id);
      this.dirtyQuestions.add(id);
      this.changed = true;
    } else {
      this.releaseQuestionRows(id);
      this.questions.delete(id);
      this.questionOrder.delete(id);
      this.dirtyQuestions.add(id);
      this.changed = true;
    }
    return true;
  }

  private releaseQuestionRows(id: string): void {
    const keys = this.questionRows.get(id);
    if (!keys) return;
    this.releaseKeys(keys);
    this.questionRows.delete(id);
  }

  apply(change: SessionListChange): void {
    if (change.sid && change.sid !== this.sid) return;
    switch (change.kind) {
      case "rows":
        this.applyRows(change);
        return;
      case "page": {
        if (change.rows.length > LIST_MAX_ROWS) {
          this.error = "list.rows";
          this.changed = true;
          return;
        }
        if (!this.questions.has(change.id)) {
          if (this.pendingPages.size >= LIST_MAX_QUESTIONS) {
            const oldest = this.pendingPages.keys().next().value;
            if (oldest) this.pendingPages.delete(oldest);
          }
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
      case "on":
        this.off = undefined;
        this.changed = true;
        return;
      case "off":
        this.off = change.code;
        this.changed = true;
        return;
      case "error":
        if (change.id) {
          const question = this.questions.get(change.id);
          if (question) {
            this.questions.set(change.id, { ...question, state: "failed", complete: false, error: change.code });
            this.changed = true;
          }
        } else {
          this.error = change.code;
          this.changed = true;
        }
    }
  }

  private applyRows(change: Extract<SessionListChange, { kind: "rows" }>): void {
    this.dirtySlots.add(change.slot);
    const slot = this.slots.get(change.slot) ?? new Map<string, undefined>();
    const removals = change.remove.map(refOf).filter((key) => slot.has(key));
    const additions = change.upserts
      .map(normalizeRow)
      .filter((row): row is SessionListRow => row !== null)
      .map(keyOf)
      .filter((key) => !slot.has(key));
    for (const key of [...removals, ...additions]) this.markKey(key);
    if (change.slot !== "live" && slot.size - removals.length + additions.length > LIST_MAX_ROWS) {
      this.error = "list.rows";
      this.changed = true;
      return;
    }
    for (const key of removals) {
      slot.delete(key);
      const count = (this.holders.get(key) ?? 1) - 1;
      if (count > 0) this.holders.set(key, count);
      else {
        this.holders.delete(key);
        this.rows.delete(key);
      }
    }
    for (const raw of change.upserts) {
      const row = normalizeRow(raw);
      if (!row) continue;
      const key = keyOf(row);
      this.markKey(key);
      this.rows.set(key, row);
      if (!slot.has(key)) {
        slot.set(key, undefined);
        this.holders.set(key, (this.holders.get(key) ?? 0) + 1);
      }
    }
    this.slots.set(change.slot, slot);
    this.slotComplete.set(change.slot, change.complete);
    this.ready = true;
    this.changed = true;
  }

  private applyPage(change: Extract<SessionListChange, { kind: "page" }>): void {
    const question = this.questions.get(change.id);
    if (!question) return;
    const rows = Object.freeze(
      change.rows.flatMap((row) => {
        const normalized = normalizeRow(row);
        return normalized ? [normalized] : [];
      }),
    );
    const previous = this.questionRows.get(change.id);
    this.dirtyQuestions.add(change.id);
    if (previous) for (const key of previous) this.markKey(key);
    if (previous) this.releaseKeys(previous);
    const keys = new Set<string>();
    for (const row of rows) {
      const key = keyOf(row);
      this.markKey(key);
      this.rows.set(key, row);
      keys.add(key);
      this.holders.set(key, (this.holders.get(key) ?? 0) + 1);
    }
    this.questionRows.set(change.id, keys);
    this.questions.set(change.id, {
      id: change.id,
      kind: question.kind,
      rows,
      hasBefore: change.hasBefore,
      hasAfter: change.hasAfter,
      coldUnread: change.coldUnread,
      deeper: change.deeper,
      missing: change.missing,
      unknown: change.unknown,
      state: change.complete ? "complete" : "pending",
      complete: change.complete,
    });
    this.changed = true;
  }

  settle(): SessionListSnapshot | null {
    if (!this.changed) return null;
    this.snapshot = this.build();
    this.changed = false;
    return this.snapshot;
  }

  close(): void {
    for (const slot of this.slots.values())
      for (const key of slot.keys()) {
        const count = (this.holders.get(key) ?? 1) - 1;
        if (count > 0) this.holders.set(key, count);
        else {
          this.holders.delete(key);
          this.rows.delete(key);
        }
      }
    this.slots.clear();
    this.slotComplete.clear();
    for (const keys of this.questionRows.values()) this.releaseKeys(keys);
    this.questions.clear();
    this.questionOrder.clear();
    this.questionRows.clear();
    this.origins.clear();
    this.pendingPages.clear();
    this.error = undefined;
    this.dirtyAll = true;
    this.snapshot = this.build();
    this.changed = false;
  }

  private build(): SessionListSnapshot {
    const slots = this.dirtyAll ? new Map<string, readonly SessionListRow[]>() : new Map(this.snapshot.slots);
    const slotComplete = this.dirtyAll ? new Map<string, boolean>() : new Map(this.snapshot.slotComplete);
    const slotNames = this.dirtyAll ? [...this.slots.keys()] : [...this.dirtySlots];
    for (const name of slotNames) {
      const keys = this.slots.get(name);
      if (!keys) {
        slots.delete(name);
        slotComplete.delete(name);
        continue;
      }
      const values = [...keys.keys()]
        .flatMap((key) => {
          const row = this.rows.get(key);
          return row ? [row] : [];
        })
        .sort((a, b) => compareOrder(sessionListOrder(a), sessionListOrder(b)));
      slots.set(name, Object.freeze(values) as readonly SessionListRow[]);
      slotComplete.set(name, this.slotComplete.get(name) ?? false);
    }
    const questions = this.dirtyAll ? new Map<string, SessionListQuestion>() : new Map(this.snapshot.questions);
    const questionIds = this.dirtyAll ? [...this.questions.keys()] : [...this.dirtyQuestions];
    for (const id of questionIds) {
      const question = this.questions.get(id);
      if (!question) {
        questions.delete(id);
        continue;
      }
      questions.set(id, {
        ...question,
        rows: Object.freeze(
          [...(this.questionRows.get(id) ?? [])]
            .flatMap((key) => {
              const row = this.rows.get(key);
              return row ? [row] : [];
            })
            .sort((a, b) => compareOrder(sessionListOrder(a), sessionListOrder(b))),
        ),
      });
    }
    this.dirtyAll = false;
    this.dirtySlots.clear();
    this.dirtyQuestions.clear();
    return {
      sid: this.sid,
      slots,
      slotComplete,
      questions,
      origins: new Map(this.origins),
      ready: this.ready,
      ...(this.off ? { off: this.off } : {}),
      ...(this.error ? { error: this.error } : {}),
    };
  }

  holds(key: string): boolean {
    return (
      [...this.slots.values()].some((slot) => slot.has(key)) ||
      [...this.questionRows.values()].some((rows) => rows.has(key))
    );
  }

  refresh(keys?: readonly string[]): void {
    this.changed = true;
    if (!keys) {
      this.dirtyAll = true;
      return;
    }
    for (const key of keys) this.markKey(key);
  }

  private markKey(key: string): void {
    for (const [name, slot] of this.slots) if (slot.has(key)) this.dirtySlots.add(name);
    for (const [id, rows] of this.questionRows) if (rows.has(key)) this.dirtyQuestions.add(id);
  }

  private releaseKeys(keys: ReadonlySet<string>): void {
    for (const key of keys) {
      const count = (this.holders.get(key) ?? 1) - 1;
      if (count > 0) this.holders.set(key, count);
      else {
        this.holders.delete(key);
        this.rows.delete(key);
      }
    }
  }
}

function compareOrder(a: [number, string, string], b: [number, string, string]): number {
  const codeUnits = (left: string, right: string): number => (left < right ? -1 : left > right ? 1 : 0);
  return b[0] - a[0] || codeUnits(b[1], a[1]) || codeUnits(b[2], a[2]);
}

type Listener = (snapshot: SessionListSnapshot) => void;

export class SessionListStore {
  private sids = new Map<string, SidList>();
  private listeners = new Map<string, Set<Listener>>();
  private rows = new Map<string, SessionListRow>();
  private holders = new Map<string, number>();
  private questionOrder = 0;

  open(sid: string): void {
    if (!this.sids.has(sid)) this.sids.set(sid, new SidList(sid, this.rows, this.holders, () => ++this.questionOrder));
  }

  close(sid: string): void {
    this.sids.get(sid)?.close();
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

  closeQuestion(sid: string, id: string): boolean {
    const list = this.sids.get(sid);
    if (!list) return false;
    return list.closeQuestion(id);
  }

  apply(change: SessionListChange): readonly string[] {
    if (change.sid) {
      const list = this.sids.get(change.sid);
      if (!list) return [];
      list.apply(change);
      const touched = new Set([change.sid]);
      if (change.kind === "rows") {
        const keys = [
          ...change.upserts
            .map((row) => normalizeRow(row))
            .filter((row): row is SessionListRow => row !== null)
            .map(keyOf),
          ...change.remove.map(refOf),
        ];
        for (const [sid, other] of this.sids) {
          if (sid !== change.sid && keys.some((key) => other.holds(key))) {
            other.refresh(keys);
            touched.add(sid);
          }
        }
      }
      if (change.kind === "page") {
        const keys = change.rows.map((row) => keyOf(row));
        for (const [sid, other] of this.sids) {
          if (sid !== change.sid && keys.some((key) => other.holds(key))) {
            other.refresh(keys);
            touched.add(sid);
          }
        }
      }
      return [...touched];
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

/** One row map and holder table per document, shared by all session-list hosts. */
export const documentSessionListStore = new SessionListStore();

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
  const change = parsed as Record<string, unknown>;
  const kind = change.kind;
  if (kind !== "rows" && kind !== "page" && kind !== "on" && kind !== "origin" && kind !== "off" && kind !== "error")
    return null;
  if (kind !== "off" && kind !== "error" && typeof change.sid !== "string") return null;
  if (kind === "rows") {
    if (
      typeof change.slot !== "string" ||
      !Array.isArray(change.upserts) ||
      !Array.isArray(change.remove) ||
      (change.complete !== undefined && typeof change.complete !== "boolean")
    )
      return null;
  }
  if (kind === "page") {
    if (
      typeof change.id !== "string" ||
      !Array.isArray(change.rows) ||
      typeof change.hasBefore !== "boolean" ||
      typeof change.hasAfter !== "boolean" ||
      (change.complete !== undefined && typeof change.complete !== "boolean")
    )
      return null;
  }
  if (kind === "origin" && (typeof change.origin !== "string" || typeof change.state !== "string")) return null;
  if ((kind === "off" || kind === "error") && typeof change.code !== "string") return null;
  if (kind === "off" || kind === "error") {
    if (change.sid === null) delete change.sid;
    if (change.sid !== undefined && typeof change.sid !== "string") return null;
  }
  if (kind === "rows" && change.complete === undefined) change.complete = false;
  if (kind === "page") {
    if (change.complete === undefined) change.complete = false;
    if (change.coldUnread === undefined) change.coldUnread = false;
    if (change.deeper === undefined) change.deeper = [];
    if (change.missing === undefined) change.missing = [];
    if (change.unknown === undefined) change.unknown = [];
  }
  return change as SessionListChange;
}
