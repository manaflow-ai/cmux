// OptChat-style room memory (plans/cmux-next/optchat.md): every entry is kept verbatim in an
// append-only log; a binary tree folds older entries into short summaries; the view is the list of
// tree nodes that covers the whole log, oldest first, rendered as `id+n|text` lines.
//
// Fold rule: the newest `keepRecent` entries stay level 0. Older nodes merge with their equal-level
// neighbour, oldest pair first, never split. A pair whose text fits `freeBytes` merges for free
// (joined text); a larger pair is summarized by the cheap model.

export type EntryKind = "speech" | "screen" | "ai" | "task" | "join";

export interface Entry {
  id: number;
  kind: EntryKind;
  speaker: string;
  text: string;
  at: number;
}

export interface MemoryNode {
  /** First entry id the node covers. */
  start: number;
  /** Entries covered. */
  n: number;
  level: number;
  text: string;
}

export type Summarize = (left: MemoryNode, right: MemoryNode) => Promise<string>;

export interface MemoryOptions {
  keepRecent?: number;
  freeBytes?: number;
  summarize: Summarize;
  /** Persists one appended entry (the log); default keeps it in memory only. */
  persist?: (entry: Entry) => void;
}

export function entryLine(entry: Entry): string {
  if (entry.kind === "speech") return `${entry.speaker}: ${entry.text}`;
  return `${entry.kind} (${entry.speaker}): ${entry.text}`;
}

const byteLength = (text: string) => new TextEncoder().encode(text).length;

export class RoomMemory {
  readonly entries: Entry[] = [];
  private nodes: MemoryNode[] = [];
  private readonly keepRecent: number;
  private readonly freeBytes: number;
  private readonly summarize: Summarize;
  private readonly persist?: (entry: Entry) => void;
  private folding: Promise<void> | null = null;

  constructor(options: MemoryOptions) {
    this.keepRecent = options.keepRecent ?? 12;
    this.freeBytes = options.freeBytes ?? 512;
    this.summarize = options.summarize;
    this.persist = options.persist;
  }

  /** Restores entries from a saved log without persisting them again. */
  restore(entries: Entry[]): void {
    for (const entry of entries) this.push(entry);
  }

  append(kind: EntryKind, speaker: string, text: string, at = Date.now()): Entry {
    const entry: Entry = { id: this.nextId(), kind, speaker, text, at };
    this.push(entry);
    this.persist?.(entry);
    return entry;
  }

  /** Runs every due merge; resolves when the view is settled. */
  settle(): Promise<void> {
    if (!this.folding) {
      this.folding = this.foldAll().finally(() => {
        this.folding = null;
      });
    }
    return this.folding;
  }

  view(): MemoryNode[] {
    return this.nodes.map((node) => ({ ...node }));
  }

  render(): string {
    return this.nodes.map(renderNode).join("\n");
  }

  /** Entries since (and excluding) `afterId`. */
  since(afterId: number): Entry[] {
    return this.entries.filter((entry) => entry.id > afterId);
  }

  /** Credits an entry to another speaker (cross-mic dedupe found the louder, real speaker). */
  reattribute(id: number, speaker: string): void {
    const entry = this.entries.find((candidate) => candidate.id === id);
    if (!entry) return;
    entry.speaker = speaker;
    const node = this.nodes.find((candidate) => candidate.level === 0 && candidate.start === id);
    if (node) node.text = entryLine(entry);
  }

  /** Drops entries older than `cutoff` from the log and the view (retention). */
  prune(cutoff: number): number {
    const keep = this.entries.findIndex((entry) => entry.at >= cutoff);
    const drop = keep === -1 ? this.entries.length : keep;
    if (drop === 0) return 0;
    const firstKept = this.entries[drop]?.id ?? Number.POSITIVE_INFINITY;
    this.entries.splice(0, drop);
    this.nodes = this.nodes.filter((node) => node.start + node.n - 1 >= firstKept);
    const head = this.nodes[0];
    if (head && head.start < firstKept) {
      // A summary that spans the cutoff is rebuilt from what is left.
      const covered = this.entries.filter((entry) => entry.id < head.start + head.n);
      this.nodes.splice(0, 1, ...covered.map(leaf));
    }
    return drop;
  }

  private nextId(): number {
    const last = this.entries.at(-1);
    return last ? last.id + 1 : 1;
  }

  private push(entry: Entry): void {
    this.entries.push(entry);
    this.nodes.push(leaf(entry));
  }

  private duePair(): number {
    // Nodes covering the newest `keepRecent` entries stay as they are.
    const total = this.entries.length;
    let covered = 0;
    let limit = this.nodes.length;
    for (let i = this.nodes.length - 1; i >= 0; i -= 1) {
      covered += this.nodes[i]!.n;
      if (covered > this.keepRecent) break;
      limit = i;
    }
    if (total <= this.keepRecent) return -1;
    for (let i = 0; i + 1 < limit; i += 1) {
      if (this.nodes[i]!.level === this.nodes[i + 1]!.level) return i;
    }
    return -1;
  }

  private async foldAll(): Promise<void> {
    for (;;) {
      const index = this.duePair();
      if (index < 0) return;
      const left = this.nodes[index]!;
      const right = this.nodes[index + 1]!;
      const joined = `${left.text}\n${right.text}`;
      const text = byteLength(joined) <= this.freeBytes ? joined : await this.summarize(left, right);
      // The log may have been pruned while the model ran; merge only if the pair is still there.
      if (this.nodes[index] !== left || this.nodes[index + 1] !== right) continue;
      this.nodes.splice(index, 2, { start: left.start, n: left.n + right.n, level: left.level + 1, text });
    }
  }
}

/** One view line; newlines show as spaces, so every node is exactly one line. */
export function renderNode(node: MemoryNode): string {
  return `${node.start}+${node.n}|${node.text.replace(/\s*\n\s*/g, " ")}`;
}

function leaf(entry: Entry): MemoryNode {
  return { start: entry.id, n: 1, level: 0, text: entryLine(entry) };
}
