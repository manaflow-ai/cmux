import type { AcpmuxRow } from "./model";

/// One prompt as the index names it.
export type PromptHead = { seq: number; at: number; text: string; promptId?: string };

/// A chat's prompt index (`_acpmux/events` `promptIndex`): each prompt older than the held rows, by seq, oldest first,
/// with its time, the start of its text and its promptId. It is held as columns, never as an object a prompt: a
/// 100k-row chat's 50k prompts were a row, a turn, a tick and a key map entry each in the rail, about 15 MB of the
/// renderer's heap a chat (bench/chat-100k-flat.bench.ts). Readers ask for one prompt at a time (railRows.ts names
/// only the rows it draws or looks up).
///
/// Plain data, read through the `PromptHeads` functions: a snapshot is copied with `structuredClone` on its way to a
/// gallery's pane, and a copy keeps typed arrays and strings but no class's methods.
export type PromptHeads = {
  /// The prompts this view holds: a prefix of the columns (`PromptHeads.before`).
  readonly length: number;
  readonly seqs: Float64Array;
  readonly ats: Float64Array;
  /// Every prompt's text joined, and where each starts (one more than `seqs`: the last is the end).
  readonly texts: string;
  readonly textStarts: Uint32Array;
  /// The promptIds the same way, when any prompt has one. A promptId an earlier prompt already has is left out (an
  /// empty string), so every prompt's key is its own (railRows.ts `indexedTurn`; model.ts `ticksOf` did the same).
  readonly promptIds?: string;
  readonly promptIdStarts?: Uint32Array;
};

function joined(values: readonly string[]): { text: string; starts: Uint32Array } {
  const starts = new Uint32Array(values.length + 1);
  let at = 0;
  for (let index = 0; index < values.length; index += 1) {
    starts[index] = at;
    at += values[index]!.length;
  }
  starts[values.length] = at;
  return { text: values.join(""), starts };
}

function of(heads: readonly PromptHead[]): PromptHeads {
  const seqs = new Float64Array(heads.length);
  const ats = new Float64Array(heads.length);
  heads.forEach((head, index) => {
    seqs[index] = head.seq;
    ats[index] = head.at;
  });
  const texts = joined(heads.map((head) => head.text));
  const seen = new Set<string>();
  const ids = heads.map((head) => {
    const id = head.promptId ?? "";
    if (!id || seen.has(id)) return "";
    seen.add(id);
    return id;
  });
  const promptIds = seen.size ? joined(ids) : undefined;
  return {
    length: heads.length,
    seqs,
    ats,
    texts: texts.text,
    textStarts: texts.starts,
    ...(promptIds ? { promptIds: promptIds.text, promptIdStarts: promptIds.starts } : {}),
  };
}

function countBefore(heads: PromptHeads, seq: number): number {
  let low = 0;
  let high = heads.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (heads.seqs[middle]! < seq) low = middle + 1;
    else high = middle;
  }
  return low;
}

const text = (heads: PromptHeads, index: number): string =>
  heads.texts.slice(heads.textStarts[index]!, heads.textStarts[index + 1]!);

const promptId = (heads: PromptHeads, index: number): string | undefined =>
  heads.promptIds === undefined || !heads.promptIdStarts
    ? undefined
    : heads.promptIds.slice(heads.promptIdStarts[index]!, heads.promptIdStarts[index + 1]!) || undefined;

export const PromptHeads = {
  EMPTY: of([]),
  of,
  /// The index of rows as a reader holds them (`user-<seq>` ids): tests and galleries.
  fromRows(rows: readonly AcpmuxRow[]): PromptHeads {
    return of(
      rows.map((row) => ({
        seq: Number(row.id.slice("user-".length)),
        at: row.at,
        text: row.text ?? "",
        ...(row.promptId ? { promptId: row.promptId } : {}),
      })),
    );
  },
  seq: (heads: PromptHeads, index: number): number => heads.seqs[index]!,
  id: (heads: PromptHeads, index: number): string => `user-${heads.seqs[index]!}`,
  text,
  promptId,
  /// The prompt as a row (direct.ts `indexedPromptPlaceholders`).
  row(heads: PromptHeads, index: number): AcpmuxRow {
    const id = promptId(heads, index);
    return {
      id: `user-${heads.seqs[index]!}`,
      version: 1,
      at: heads.ats[index]!,
      kind: "user",
      text: text(heads, index),
      ...(id ? { promptId: id } : {}),
    };
  },
  /// The prompt at `index` as one head.
  head(heads: PromptHeads, index: number): PromptHead {
    const id = promptId(heads, index);
    return {
      seq: heads.seqs[index]!,
      at: heads.ats[index]!,
      text: text(heads, index),
      ...(id ? { promptId: id } : {}),
    };
  },
  /// `heads`' prompts with seq in [from, before) and `extra`'s there, one a seq (`heads`' wins), oldest first: a
  /// window of the chat keeps the prompts it let go of beside the index's (direct.ts `shedPrompts`, `newerLeft`).
  /// `heads` itself when `extra` adds none and nothing is cut. O(the prompts kept + extra).
  merged(heads: PromptHeads, extra: Iterable<PromptHead>, from = -Infinity, before = Infinity): PromptHeads {
    const start = countBefore(heads, from);
    const end = countBefore(heads, before);
    const bySeq = new Map<number, PromptHead>();
    for (const head of extra)
      if (head.seq >= from && head.seq < before && PromptHeads.indexOfSeq(heads, head.seq) < 0)
        bySeq.set(head.seq, head);
    if (bySeq.size === 0 && start === 0) return end === heads.length ? heads : { ...heads, length: end };
    const list: PromptHead[] = [];
    for (let index = start; index < end; index += 1) list.push(PromptHeads.head(heads, index));
    list.push(...bySeq.values());
    list.sort((a, b) => a.seq - b.seq);
    return of(list);
  },
  /// The number of prompts before `seq`.
  countBefore,
  /// The prompts before `seq`, sharing these columns: `heads` itself when it holds no later one.
  before(heads: PromptHeads, seq: number): PromptHeads {
    const end = countBefore(heads, seq);
    return end === heads.length ? heads : { ...heads, length: end };
  },
  /// Where the prompt at `seq` is, or -1.
  indexOfSeq(heads: PromptHeads, seq: number): number {
    const at = countBefore(heads, seq);
    return at < heads.length && heads.seqs[at] === seq ? at : -1;
  },
  /// Where the prompt keyed by `id` is, or -1. A scan of the column: callers keep what they found.
  indexOfPromptId(heads: PromptHeads, id: string): number {
    const ids = heads.promptIds;
    const starts = heads.promptIdStarts;
    if (ids === undefined || !starts) return -1;
    for (let index = 0; index < heads.length; index += 1) {
      const from = starts[index]!;
      if (starts[index + 1]! - from === id.length && ids.startsWith(id, from)) return index;
    }
    return -1;
  },
};
