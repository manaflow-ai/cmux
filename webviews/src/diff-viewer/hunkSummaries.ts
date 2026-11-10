// Plain English (PlainEnglishView.tsx): one sentence per hunk, asked of the host
// (`cmux.diff.summary`, which relays to acpmux's `_acpmux/hunk_summary`) only for the hunks on
// screen or just past it. acpmux keeps each sentence by the hunk's content hash, so a reopened
// diff runs nothing and a changed hunk is asked again alone; this page keeps what it was told
// by the same content, so scrolling back asks nothing.
//
// At most `MAX_IN_FLIGHT` asks run at once. A hunk that leaves the window before its turn is
// dropped from the queue, never sent.

export const DIFF_PAGE_SUMMARY_OP = "cmux.diff.summary";
export const DIFF_PAGE_SUMMARY_CHECK_OP = "cmux.diff.summaryCheck";

/** Asks running at once. acpmux runs at most 4 completions for every caller together. */
export const MAX_IN_FLIGHT = 2;
/** Sentences this page keeps (each about 100 bytes). */
export const PAGE_CACHE_CAP = 4000;
/** The longest patch asked about: acpmux's own limit (`hunk_summary.rs`). */
export const MAX_PATCH_BYTES = 256 * 1024;

type HunkContent =
  | { type: "context"; lines: number; additionLineIndex: number; deletionLineIndex: number }
  | { type: "change"; deletions: number; deletionLineIndex: number; additions: number; additionLineIndex: number };

/** The parts of Pierre's `Hunk` and `FileDiffMetadata` a hunk's patch is built from. */
export type SummaryHunk = {
  additionStart: number;
  additionCount: number;
  deletionStart: number;
  deletionCount: number;
  hunkContext?: string;
  hunkContent: readonly HunkContent[];
};
export type SummaryFileDiff = {
  name: string;
  prevName?: string;
  hunks: readonly SummaryHunk[];
  additionLines: readonly string[];
  deletionLines: readonly string[];
};

/** One hunk of the diff, as the page asks about it. */
export type HunkRef = {
  /** `<itemId>#<index>`: the row's id. */
  id: string;
  itemId: string;
  index: number;
  path: string;
  /** The hunk's unified patch: its `@@` header and lines. */
  patch: string;
  /** The page's cache key: the path and patch (`contentKey`). */
  key: string;
  /** Its first changed line, shown while the sentence loads. */
  preview: string;
  additions: number;
  deletions: number;
};

const stripEol = (line: string | undefined) => (line ?? "").replace(/\r?\n$/, "");

/** Hunk `hunk`'s unified patch text, as `git diff` writes it. */
export function hunkPatch(fileDiff: SummaryFileDiff, hunk: SummaryHunk): string {
  const context = hunk.hunkContext ? ` ${hunk.hunkContext}` : "";
  const out = [
    `@@ -${hunk.deletionStart},${hunk.deletionCount} +${hunk.additionStart},${hunk.additionCount} @@${context}`,
  ];
  for (const part of hunk.hunkContent) {
    if (part.type === "context") {
      for (let i = 0; i < part.lines; i++) out.push(` ${stripEol(fileDiff.additionLines[part.additionLineIndex + i])}`);
    } else {
      for (let i = 0; i < part.deletions; i++)
        out.push(`-${stripEol(fileDiff.deletionLines[part.deletionLineIndex + i])}`);
      for (let i = 0; i < part.additions; i++)
        out.push(`+${stripEol(fileDiff.additionLines[part.additionLineIndex + i])}`);
    }
  }
  return out.join("\n");
}

/** A 53-bit FNV-1a-style hash of `text` in hex: the page's own key, not acpmux's (SHA-256). */
export function contentKey(path: string, patch: string): string {
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  const text = `${path}\u0000${patch}`;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193);
    h2 = Math.imul(h2 ^ c, 0x5bd1e995);
  }
  return `${(h1 >>> 0).toString(16).padStart(8, "0")}${((h2 >>> 0) & 0x1fffff).toString(16).padStart(6, "0")}:${text.length}`;
}

/** The hunks of one diff item, in order; none for an item without a parsed diff. */
export function hunkRefs(itemId: string, fileDiff: SummaryFileDiff | null | undefined): HunkRef[] {
  if (!fileDiff?.hunks) return [];
  const path = fileDiff.name || fileDiff.prevName || itemId;
  return fileDiff.hunks.map((hunk, index) => {
    const patch = hunkPatch(fileDiff, hunk);
    let additions = 0;
    let deletions = 0;
    let preview = "";
    for (const part of hunk.hunkContent) {
      if (part.type !== "change") continue;
      additions += part.additions;
      deletions += part.deletions;
      if (preview === "") {
        preview =
          part.additions > 0
            ? stripEol(fileDiff.additionLines[part.additionLineIndex])
            : stripEol(fileDiff.deletionLines[part.deletionLineIndex]);
      }
    }
    return {
      id: `${itemId}#${index}`,
      itemId,
      index,
      path,
      patch,
      key: contentKey(path, patch),
      preview: preview.trim(),
      additions,
      deletions,
    };
  });
}

export type SummaryState = { kind: "loading" } | { kind: "ready"; text: string } | { kind: "failed" };

/** What one ask answers: the sentence, or throws. */
export type SummaryAsk = (path: string, patch: string) => Promise<string>;

/** Reads `{text}` from a `cmux.diff.summary` answer. */
export function summaryText(answer: unknown): string | null {
  const text = (answer as { text?: unknown } | null)?.text;
  return typeof text === "string" && text.trim() !== "" ? text.trim() : null;
}

/**
 * The sentences of one diff tab. `want` names the hunks in or near the window, in reading order;
 * only those are asked for, at most `maxInFlight` at once, and a hunk no longer wanted is dropped
 * from the queue. Rows read a hunk's state with `get` and hear of changes with `subscribe`.
 */
export class SummaryStore {
  private readonly states = new Map<string, SummaryState>();
  private readonly listeners = new Map<string, Set<() => void>>();
  private wanted: HunkRef[] = [];
  private readonly running = new Set<string>();
  private closed = false;

  constructor(
    private readonly ask: SummaryAsk,
    private readonly maxInFlight = MAX_IN_FLIGHT,
    private readonly cap = PAGE_CACHE_CAP,
  ) {}

  /** A hunk's sentence state; a hunk not asked about yet is loading. */
  get(key: string): SummaryState {
    return this.states.get(key) ?? LOADING;
  }

  subscribe(key: string, listener: () => void): () => void {
    let set = this.listeners.get(key);
    if (!set) this.listeners.set(key, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0) this.listeners.delete(key);
    };
  }

  /** The hunks in or near the window now, in reading order: the queue becomes these. */
  want(refs: readonly HunkRef[]): void {
    this.wanted = refs.filter((ref) => !this.states.has(ref.key));
    this.pump();
  }

  /** How many asks run now (tests). */
  get inFlight(): number {
    return this.running.size;
  }

  /** Stops asking: answers that come back after are dropped. */
  close(): void {
    this.closed = true;
    this.wanted = [];
    this.listeners.clear();
  }

  private pump(): void {
    while (!this.closed && this.running.size < this.maxInFlight) {
      const next = this.wanted.find((ref) => !this.running.has(ref.key) && !this.states.has(ref.key));
      if (!next) return;
      this.run(next);
    }
  }

  private run(ref: HunkRef): void {
    this.running.add(ref.key);
    const finish = (state: SummaryState) => {
      this.running.delete(ref.key);
      if (this.closed) return;
      this.set(ref.key, state);
      this.wanted = this.wanted.filter((wanted) => wanted.key !== ref.key);
      this.pump();
    };
    const tooBig = new TextEncoder().encode(ref.patch).length > MAX_PATCH_BYTES;
    if (tooBig) {
      queueMicrotask(() => finish({ kind: "failed" }));
      return;
    }
    this.ask(ref.path, ref.patch).then(
      (text) => finish(text.trim() ? { kind: "ready", text: text.trim() } : { kind: "failed" }),
      () => finish({ kind: "failed" }),
    );
  }

  private set(key: string, state: SummaryState): void {
    this.states.delete(key);
    this.states.set(key, state);
    // The oldest go first past the cap; a row showing one asks again when it is next wanted.
    while (this.states.size > this.cap) {
      const oldest = this.states.keys().next().value as string;
      this.states.delete(oldest);
    }
    for (const listener of this.listeners.get(key) ?? []) listener();
  }
}

const LOADING: SummaryState = { kind: "loading" };

/** Why Plain English is off, as a label key; null when it is offered. */
export type PlainEnglishAvailability =
  | { kind: "checking" }
  | { kind: "ready" }
  | { kind: "unavailable"; reasonKey: PlainEnglishReasonKey };

export type PlainEnglishReasonKey =
  | "plainEnglishNeedsHost"
  | "plainEnglishNoAgent"
  | "plainEnglishNoHarness"
  | "plainEnglishNotInstalled"
  | "plainEnglishUnsupported"
  | "plainEnglishUnavailable";

/** The toggle's state from a `cmux.diff.summaryCheck` answer (`{ready, reason?}`). */
export function availabilityFromCheck(answer: unknown): PlainEnglishAvailability {
  const value = answer as { ready?: unknown; reason?: unknown } | null;
  if (value?.ready === true) return { kind: "ready" };
  return { kind: "unavailable", reasonKey: reasonKeyFor(typeof value?.reason === "string" ? value.reason : "") };
}

export function reasonKeyFor(reason: string): PlainEnglishReasonKey {
  switch (reason) {
    case "cmux.diff.no_acpmux":
      return "plainEnglishNoAgent";
    case "complete.unknown_harness":
      return "plainEnglishNoHarness";
    case "complete.not_installed":
      return "plainEnglishNotInstalled";
    case "complete.unsupported_harness":
      return "plainEnglishUnsupported";
    default:
      return "plainEnglishUnavailable";
  }
}
