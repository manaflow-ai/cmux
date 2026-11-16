import type { AcpmuxRow } from "./model";

/// Strings kept as one: their joined text and where each starts. A long chat's prompt index is tens of thousands of
/// short strings; as one string and one offset array it costs its characters and four bytes a string, not an
/// object each.
class StringColumn {
  private constructor(
    private readonly joined: string,
    private readonly starts: Uint32Array,
  ) {}

  static of(values: readonly string[]): StringColumn {
    const starts = new Uint32Array(values.length + 1);
    let at = 0;
    for (let index = 0; index < values.length; index += 1) {
      starts[index] = at;
      at += values[index]!.length;
    }
    starts[values.length] = at;
    return new StringColumn(values.join(""), starts);
  }

  at(index: number): string {
    return this.joined.slice(this.starts[index]!, this.starts[index + 1]!);
  }

  /// The first index below `end` whose string is `value`, or -1.
  indexOf(value: string, end: number): number {
    for (let index = 0; index < end; index += 1) {
      const from = this.starts[index]!;
      if (this.starts[index + 1]! - from === value.length && this.joined.startsWith(value, from)) return index;
    }
    return -1;
  }
}

/// One prompt as the index names it.
export type PromptHead = { seq: number; at: number; text: string; promptId?: string };

/// A chat's prompt index (`_acpmux/events` `promptIndex`): each prompt older than the held rows, by seq, oldest first,
/// with its time, the start of its text and its promptId. It is held as columns, never as an object a prompt: a
/// 100k-row chat's 50k prompts were a row, a turn, a tick and a key map entry each in the rail, about 15 MB of the
/// renderer's heap a chat (bench/chat-100k-flat.bench.ts). Readers ask for one prompt at a time (railRows.ts names
/// only the rows it draws or looks up).
export class PromptHeads {
  static readonly EMPTY = PromptHeads.of([]);

  private constructor(
    private readonly seqs: Float64Array,
    private readonly ats: Float64Array,
    private readonly texts: StringColumn,
    private readonly promptIds: StringColumn | undefined,
    /// The prompts this view holds: a prefix of the columns (`before`).
    readonly length: number,
  ) {}

  static of(heads: readonly PromptHead[]): PromptHeads {
    const seqs = new Float64Array(heads.length);
    const ats = new Float64Array(heads.length);
    let ids = false;
    heads.forEach((head, index) => {
      seqs[index] = head.seq;
      ats[index] = head.at;
      if (head.promptId) ids = true;
    });
    return new PromptHeads(
      seqs,
      ats,
      StringColumn.of(heads.map((head) => head.text)),
      ids ? StringColumn.of(heads.map((head) => head.promptId ?? "")) : undefined,
      heads.length,
    );
  }

  /// The index of rows as a reader holds them (`user-<seq>` ids): tests and galleries.
  static fromRows(rows: readonly AcpmuxRow[]): PromptHeads {
    return PromptHeads.of(
      rows.map((row) => ({
        seq: Number(row.id.slice("user-".length)),
        at: row.at,
        text: row.text ?? "",
        ...(row.promptId ? { promptId: row.promptId } : {}),
      })),
    );
  }

  seq(index: number): number {
    return this.seqs[index]!;
  }

  id(index: number): string {
    return `user-${this.seqs[index]!}`;
  }

  text(index: number): string {
    return this.texts.at(index);
  }

  promptId(index: number): string | undefined {
    return this.promptIds?.at(index) || undefined;
  }

  /// The prompt as a row (direct.ts `indexedPromptPlaceholders`).
  row(index: number): AcpmuxRow {
    const promptId = this.promptId(index);
    return {
      id: this.id(index),
      version: 1,
      at: this.ats[index]!,
      kind: "user",
      text: this.text(index),
      ...(promptId ? { promptId } : {}),
    };
  }

  /// The number of prompts before `seq`.
  countBefore(seq: number): number {
    let low = 0;
    let high = this.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (this.seqs[middle]! < seq) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  /// The prompts before `seq`, sharing these columns: this view when it holds no later one.
  before(seq: number): PromptHeads {
    const end = this.countBefore(seq);
    return end === this.length ? this : new PromptHeads(this.seqs, this.ats, this.texts, this.promptIds, end);
  }

  /// Where the prompt at `seq` is, or -1.
  indexOfSeq(seq: number): number {
    const at = this.countBefore(seq);
    return at < this.length && this.seqs[at] === seq ? at : -1;
  }

  /// Where the first prompt with `promptId` is, or -1. A scan of the column: callers keep what they found.
  indexOfPromptId(promptId: string): number {
    return this.promptIds?.indexOf(promptId, this.length) ?? -1;
  }
}
