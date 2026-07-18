export const MAX_TEXT_DOCUMENT_ATOMS = 8_000;
export const MAX_TEXT_OPERATION_ATOMS = 256;
export const MAX_TEXT_IDENTIFIER_CLOCK = 999_999_999;
export const MAX_TEXT_OPERATION_HISTORY = 16_384;

const IDENTIFIER_PATTERN = /^(\d{12}):([A-Za-z0-9._-]{1,128})$/u;

export type TextAtom = {
  readonly id: string;
  readonly afterId: string | null;
  readonly value: string;
  readonly deleted: boolean;
};

export type TextDocumentSnapshot = {
  readonly docId: string;
  readonly revision: number;
  readonly atoms: readonly TextAtom[];
};

export type TextOperation =
  | {
      readonly opId: string;
      readonly docId: string;
      readonly kind: "insert";
      readonly atoms: readonly TextAtom[];
    }
  | {
      readonly opId: string;
      readonly docId: string;
      readonly kind: "delete";
      readonly atomIds: readonly string[];
    };

export type TextDocumentView = TextDocumentSnapshot & { readonly text: string };

export type TextCompositionSnapshot = {
  readonly docId: string;
  readonly baseText: string;
  readonly baseAtoms: readonly Pick<TextAtom, "id" | "value">[];
};

export class ReplicatedTextDocument {
  readonly docId: string;
  private revisionValue: number;
  private readonly atoms = new Map<string, TextAtom>();
  private readonly appliedOperations = new Set<string>();
  private readonly appliedOperationOrder: string[] = [];
  private readonly deletedAtomIds = new Set<string>();
  private logicalClock = 0;

  constructor(snapshot: TextDocumentSnapshot) {
    this.docId = snapshot.docId;
    this.revisionValue = snapshot.revision;
    for (const atom of snapshot.atoms.slice(0, MAX_TEXT_DOCUMENT_ATOMS)) {
      if (validAtom(atom) && !this.atoms.has(atom.id)) {
        this.atoms.set(atom.id, atom);
        this.observeIdentifier(atom.id);
        if (atom.deleted) this.deletedAtomIds.add(atom.id);
      }
    }
  }

  get revision(): number {
    return this.revisionValue;
  }

  apply(operation: TextOperation, revision?: number): boolean {
    if (operation.docId !== this.docId || !validIdentifier(operation.opId)) return false;
    if (this.appliedOperations.has(operation.opId)) {
      if (revision !== undefined) this.revisionValue = Math.max(this.revisionValue, revision);
      return false;
    }
    if (operation.kind === "insert") {
      if (
        operation.atoms.length < 1 ||
        operation.atoms.length > MAX_TEXT_OPERATION_ATOMS ||
        operation.atoms.some((atom) => !validAtom({ ...atom, deleted: false }))
      ) return false;
      for (const atom of operation.atoms) {
        this.observeIdentifier(atom.id);
        if (!this.atoms.has(atom.id) && this.atoms.size < MAX_TEXT_DOCUMENT_ATOMS) {
          this.atoms.set(atom.id, { ...atom, deleted: this.deletedAtomIds.has(atom.id) });
        }
      }
    } else {
      if (
        operation.atomIds.length < 1 ||
        operation.atomIds.length > MAX_TEXT_OPERATION_ATOMS ||
        operation.atomIds.some((atomId) => !validIdentifier(atomId))
      ) return false;
      for (const atomId of operation.atomIds) {
        this.observeIdentifier(atomId);
        if (this.atoms.has(atomId) || this.deletedAtomIds.size < MAX_TEXT_DOCUMENT_ATOMS) {
          this.deletedAtomIds.add(atomId);
        }
        const current = this.atoms.get(atomId);
        if (current && !current.deleted) this.atoms.set(atomId, { ...current, deleted: true });
      }
    }
    this.observeIdentifier(operation.opId);
    this.appliedOperations.add(operation.opId);
    this.appliedOperationOrder.push(operation.opId);
    if (this.appliedOperationOrder.length >= MAX_TEXT_OPERATION_HISTORY * 2) {
      this.appliedOperationOrder.splice(0, MAX_TEXT_OPERATION_HISTORY);
      this.appliedOperations.clear();
      for (const opId of this.appliedOperationOrder) this.appliedOperations.add(opId);
    }
    this.revisionValue = Math.max(this.revisionValue + 1, revision ?? 0);
    return true;
  }

  beginComposition(): TextCompositionSnapshot {
    const baseAtoms = this.visibleAtoms().map(({ id, value }) => ({ id, value }));
    return {
      docId: this.docId,
      baseText: baseAtoms.map((atom) => atom.value).join(""),
      baseAtoms,
    };
  }

  localChange(nextText: string, clientId: string, nextCounter: () => number): readonly TextOperation[] {
    return this.localChangeFrom(this.beginComposition(), nextText, clientId, nextCounter);
  }

  localChangeFrom(
    snapshot: TextCompositionSnapshot,
    nextText: string,
    clientId: string,
    nextCounter: () => number,
  ): readonly TextOperation[] {
    if (snapshot.docId !== this.docId || !validClientId(clientId)) return [];
    const before = snapshot.baseAtoms.map((atom) => atom.value);
    const after = graphemes(nextText);
    if (after.length > MAX_TEXT_DOCUMENT_ATOMS) return [];
    let prefix = 0;
    while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix += 1;
    let suffix = 0;
    while (
      suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before[before.length - 1 - suffix] === after[after.length - 1 - suffix]
    ) suffix += 1;

    const operations: TextOperation[] = [];
    const removed = snapshot.baseAtoms.slice(prefix, before.length - suffix).map((atom) => atom.id);
    for (const atomIds of chunks(removed, MAX_TEXT_OPERATION_ATOMS)) {
      const opId = this.nextIdentifier(clientId, nextCounter);
      if (!opId) return operations;
      const operation: TextOperation = {
        opId,
        docId: this.docId,
        kind: "delete",
        atomIds,
      };
      if (this.apply(operation)) operations.push(operation);
    }

    const inserted = after.slice(prefix, after.length - suffix);
    let afterId = prefix > 0 ? snapshot.baseAtoms[prefix - 1]?.id ?? null : null;
    for (const values of chunks(inserted, MAX_TEXT_OPERATION_ATOMS)) {
      const atoms: TextAtom[] = [];
      for (const value of values) {
        const id = this.nextIdentifier(clientId, nextCounter);
        if (!id) return operations;
        const atom: TextAtom = { id, afterId, value, deleted: false };
        afterId = id;
        atoms.push(atom);
      }
      const opId = this.nextIdentifier(clientId, nextCounter);
      if (!opId) return operations;
      const operation: TextOperation = {
        opId,
        docId: this.docId,
        kind: "insert",
        atoms,
      };
      if (this.apply(operation)) operations.push(operation);
    }
    return operations;
  }

  view(): TextDocumentView {
    return {
      docId: this.docId,
      revision: this.revisionValue,
      atoms: [...this.atoms.values()],
      text: this.visibleAtoms().map((atom) => atom.value).join(""),
    };
  }

  private visibleAtoms(): TextAtom[] {
    const children = new Map<string | null, TextAtom[]>();
    for (const atom of this.atoms.values()) {
      const parent = atom.afterId !== null && this.atoms.has(atom.afterId) ? atom.afterId : null;
      const siblings = children.get(parent) ?? [];
      siblings.push(atom);
      children.set(parent, siblings);
    }
    for (const siblings of children.values()) {
      siblings.sort((left, right) => left.id > right.id ? -1 : left.id < right.id ? 1 : 0);
    }
    const result: TextAtom[] = [];
    const seen = new Set<string>();
    const visit = (parent: string | null) => {
      for (const atom of children.get(parent) ?? []) {
        if (seen.has(atom.id)) continue;
        seen.add(atom.id);
        if (!atom.deleted) result.push(atom);
        visit(atom.id);
      }
    };
    visit(null);
    return result;
  }

  private nextIdentifier(clientId: string, nextCounter: () => number): string | null {
    const candidate = nextCounter();
    this.logicalClock = Math.max(this.logicalClock + 1, Number.isSafeInteger(candidate) ? candidate : 0);
    if (this.logicalClock > MAX_TEXT_IDENTIFIER_CLOCK) return null;
    return `${String(this.logicalClock).padStart(12, "0")}:${clientId}`;
  }

  private observeIdentifier(identifier: string): void {
    const clock = identifierClock(identifier);
    if (clock !== null) this.logicalClock = Math.max(this.logicalClock, clock);
  }
}

export function snapshotFromText(docId: string, text: string, clientId = "host"): TextDocumentSnapshot {
  if (!validClientId(clientId)) throw new Error("invalid_text_client_id");
  let afterId: string | null = null;
  const atoms = graphemes(text).slice(0, MAX_TEXT_DOCUMENT_ATOMS).map((value, index) => {
    const id = `${String(index + 1).padStart(12, "0")}:${clientId}`;
    const atom: TextAtom = { id, afterId, value, deleted: false };
    afterId = id;
    return atom;
  });
  return { docId, revision: 0, atoms };
}

export function parseTextDocumentSnapshot(value: unknown): TextDocumentSnapshot | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const snapshot = value as Record<string, unknown>;
  if (
    typeof snapshot.docId !== "string" || snapshot.docId.length < 1 || snapshot.docId.length > 128 ||
    typeof snapshot.revision !== "number" || !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0 ||
    !Array.isArray(snapshot.atoms) || snapshot.atoms.length > MAX_TEXT_DOCUMENT_ATOMS
  ) return null;
  const atoms: TextAtom[] = [];
  for (const value of snapshot.atoms) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const atom = value as Record<string, unknown>;
    const candidate: TextAtom = {
      id: typeof atom.id === "string" ? atom.id : "",
      afterId: atom.afterId === null ? null : typeof atom.afterId === "string" ? atom.afterId : "",
      value: typeof atom.value === "string" ? atom.value : "",
      deleted: atom.deleted === true,
    };
    if (typeof atom.deleted !== "boolean" || !validAtom(candidate)) return null;
    atoms.push(candidate);
  }
  return { docId: snapshot.docId, revision: snapshot.revision, atoms };
}

export function parseTextOperation(value: unknown): TextOperation | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const operation = value as Record<string, unknown>;
  if (
    typeof operation.opId !== "string" || !validIdentifier(operation.opId) ||
    typeof operation.docId !== "string" || operation.docId.length < 1 || operation.docId.length > 128
  ) return null;
  if (
    operation.kind === "insert" &&
    Array.isArray(operation.atoms) &&
    operation.atoms.length >= 1 &&
    operation.atoms.length <= MAX_TEXT_OPERATION_ATOMS
  ) {
    const atoms: TextAtom[] = [];
    for (const value of operation.atoms) {
      if (!value || typeof value !== "object" || Array.isArray(value)) return null;
      const atom = value as Record<string, unknown>;
      const candidate: TextAtom = {
        id: typeof atom.id === "string" ? atom.id : "",
        afterId: atom.afterId === null ? null : typeof atom.afterId === "string" ? atom.afterId : "",
        value: typeof atom.value === "string" ? atom.value : "",
        deleted: false,
      };
      if (atom.deleted !== false || !validAtom(candidate)) return null;
      atoms.push(candidate);
    }
    return { opId: operation.opId, docId: operation.docId, kind: "insert", atoms };
  }
  if (
    operation.kind === "delete" &&
    Array.isArray(operation.atomIds) &&
    operation.atomIds.length >= 1 &&
    operation.atomIds.length <= MAX_TEXT_OPERATION_ATOMS &&
    operation.atomIds.every((atomId) => typeof atomId === "string" && validIdentifier(atomId))
  ) {
    return {
      opId: operation.opId,
      docId: operation.docId,
      kind: "delete",
      atomIds: operation.atomIds as string[],
    };
  }
  return null;
}

function graphemes(value: string): string[] {
  const Segmenter = Intl.Segmenter;
  if (!Segmenter) return [...value];
  return [...new Segmenter(undefined, { granularity: "grapheme" }).segment(value)].map((part) => part.segment);
}

function validAtom(atom: TextAtom): boolean {
  return (
    validIdentifier(atom.id) &&
    (atom.afterId === null || validIdentifier(atom.afterId)) &&
    typeof atom.value === "string" && graphemes(atom.value).length === 1 && utf8Length(atom.value) <= 64 &&
    typeof atom.deleted === "boolean"
  );
}

function validIdentifier(value: string): boolean {
  return IDENTIFIER_PATTERN.test(value) && identifierClock(value) !== null;
}

function validClientId(value: string): boolean {
  return /^[A-Za-z0-9._-]{1,128}$/u.test(value);
}

function identifierClock(value: string): number | null {
  const match = IDENTIFIER_PATTERN.exec(value);
  if (!match?.[1]) return null;
  const clock = Number(match[1]);
  return Number.isSafeInteger(clock) && clock <= MAX_TEXT_IDENTIFIER_CLOCK ? clock : null;
}

function utf8Length(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function chunks<T>(values: readonly T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < values.length; index += size) result.push(values.slice(index, index + size));
  return result;
}
