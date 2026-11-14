// The Cmd-K palette's ranking request (`cmux.home.paletteRank`): the page sends its rows and the
// query, and the daemon ranks them with the shared palette ranker (`palette.rank`, the Rust
// cmux-palette-ranker the app palette uses), so the page keeps no ranker of its own.

/** One palette row as the ranker reads it (the subset of `palette.rank`'s entry the page sends). */
export interface PaletteRankEntry {
  title: string;
  keywords?: string[];
  sectionIndex?: number;
  isVisibleWhenQueryEmpty?: boolean;
}

export interface PaletteRankRequest {
  entries: PaletteRankEntry[];
  query: string;
  /** Rows stay in their sections, in section order, while the person types. */
  keepsSectionOrder?: boolean;
}

export interface PaletteRankedSection {
  sectionIndex: number | null;
  rows: Array<{ index: number; score: number; highlights: number[] }>;
}

export interface PaletteRankReply {
  sections: PaletteRankedSection[];
}

/** One `palette.rank` request as the page sends it: a batch of the rows and how to rank them. */
export interface PaletteRankBatch extends PaletteRankRequest {
  rowLimit: number;
  highlightLimit: number;
  /** Absent: the ranker decides alone; false and true: the batches decided it together. */
  typoPass?: boolean;
}

/** `palette.rank`'s answer: the sections, and the rows its strict pass matched. */
export interface PaletteRankBatchReply extends PaletteRankReply {
  strictMatches?: number;
}

/** What a daemon's `palette.rank` takes: its text caps in UTF-8 bytes, and whether it has
 * `typoPass` and `strictMatches`, so several requests decide the typo pass as one. */
export interface PaletteRankContract {
  titleBytes: number;
  keywords: number;
  keywordBytes: number;
  decidesTypoPass: boolean;
}

/** `palette-rank-v2` (resource-operations-v2.json): its caps hold any title and name the app
 * allows. A 200-character title (the conversation owner's MAX_TITLE_CHARS) with a channel's "#" is
 * at most 801 bytes, and each of a conversation's 64 participants' names (100 characters) at most
 * 400. */
export const PALETTE_RANK_V2: PaletteRankContract = {
  titleBytes: 1024,
  keywords: 64,
  keywordBytes: 400,
  decidesTypoPass: true,
};
/** `palette-rank-v1`, a daemon from before v2: smaller caps, and each request decides its own
 * typo pass (a merge of several is then close to one request's answer, not equal to it). */
export const PALETTE_RANK_V1: PaletteRankContract = {
  titleBytes: 512,
  keywords: 32,
  keywordBytes: 256,
  decidesTypoPass: false,
};

/** Most rows one request carries (both versions). */
export const MAX_RANK_ENTRIES = 5000;
const MAX_QUERY_BYTES = 1024;
/** Most JSON bytes of entries one request carries (an upper bound, see `entryBytes`): with the
 * query and the envelope, under the daemon's 4 MiB WebSocket message. */
const MAX_BATCH_BYTES = 3 * 1024 * 1024;
// The ranker's defaults, sent so a merge of several batches cuts where one request would.
const ROW_LIMIT = 400;
const HIGHLIGHT_LIMIT = 60;
/** The ranker's TYPO_PASS_THRESHOLD: the typo pass runs below this many strict matches. */
const TYPO_PASS_THRESHOLD = 3;

const encoder = new TextEncoder();

/** `text` cut to at most `max` UTF-8 bytes, on a character boundary (unchanged when it fits). */
export function clipUtf8(text: string, max: number): string {
  if (text.length * 3 <= max || encoder.encode(text).length <= max) return text;
  let bytes = 0;
  let end = 0;
  for (const char of text) {
    bytes += encoder.encode(char).length;
    if (bytes > max) break;
    end += char.length;
  }
  return text.slice(0, end);
}

/** The request's text clipped to the daemon's caps, so a long title never fails the rank. Every
 * row stays: `rankPalette` splits a long list into requests the daemon takes. */
export function boundedRankRequest(
  request: PaletteRankRequest,
  contract: PaletteRankContract = PALETTE_RANK_V2,
): PaletteRankRequest {
  return {
    ...request,
    query: clipUtf8(request.query, MAX_QUERY_BYTES),
    entries: request.entries.map((entry) => ({
      ...entry,
      title: clipUtf8(entry.title, contract.titleBytes),
      keywords: entry.keywords?.slice(0, contract.keywords).map((keyword) => clipUtf8(keyword, contract.keywordBytes)),
    })),
  };
}

/** At least the JSON bytes of `entry`: a UTF-16 unit takes at most 6 (`\u001f`), each string its
 * quotes and comma, and the field names and numbers fit in the rest. */
function entryBytes(entry: PaletteRankEntry): number {
  let bytes = 96 + 6 * entry.title.length;
  for (const keyword of entry.keywords ?? []) bytes += 3 + 6 * keyword.length;
  return bytes;
}

/** The rows in runs of at most MAX_RANK_ENTRIES and MAX_BATCH_BYTES, each with its first index. */
function batches(entries: readonly PaletteRankEntry[]): Array<{ start: number; entries: PaletteRankEntry[] }> {
  const runs: Array<{ start: number; entries: PaletteRankEntry[] }> = [];
  let run: { start: number; entries: PaletteRankEntry[] } | undefined;
  let bytes = 0;
  entries.forEach((entry, index) => {
    const size = entryBytes(entry);
    if (!run || run.entries.length >= MAX_RANK_ENTRIES || bytes + size > MAX_BATCH_BYTES) {
      runs.push((run = { start: index, entries: [] }));
      bytes = 0;
    }
    run.entries.push(entry);
    bytes += size;
  });
  return runs.length ? runs : [{ start: 0, entries: [] }];
}

type Row = PaletteRankedSection["rows"][number];

/**
 * Ranks every row, in as many `palette.rank` requests as the daemon's caps need (`rankOne` sends
 * one). A list that fits is one request. A longer one is ranked in batches whose merge is the
 * answer one request over every row gives. The ranker scores each row on its own, except that its
 * typo pass runs only when fewer than three rows match strictly: so each batch ranks strictly
 * first, and when all of them together match fewer than three, all rank again with the typo pass.
 * For the page's rows (no bias, usage, shortcut, handle or alias) the ranker orders rows by score,
 * then index, and cuts them to the row limit before it groups them in sections; the merge does the
 * same with the batches' rows. On the empty query every batch lists its rows in order by section.
 * A v1 daemon has no `typoPass`: each of its batches decides the typo pass alone.
 */
export async function rankPalette(
  request: PaletteRankRequest,
  rankOne: (batch: PaletteRankBatch) => Promise<PaletteRankBatchReply>,
  contract: PaletteRankContract = PALETTE_RANK_V2,
): Promise<PaletteRankReply> {
  const bounded = boundedRankRequest(request, contract);
  const runs = batches(bounded.entries);
  const ask = (typoPass?: boolean) =>
    Promise.all(
      runs.map((run) =>
        rankOne({
          ...bounded,
          entries: run.entries,
          rowLimit: ROW_LIMIT,
          highlightLimit: HIGHLIGHT_LIMIT,
          ...(typoPass === undefined ? {} : { typoPass }),
        }),
      ),
    );
  if (runs.length === 1) {
    const [reply] = await ask();
    return { sections: reply!.sections };
  }
  const typed = bounded.query.trim() !== "";
  const decides = typed && contract.decidesTypoPass;
  let replies = await ask(decides ? false : undefined);
  if (decides && replies.reduce((sum, reply) => sum + (reply.strictMatches ?? 0), 0) < TYPO_PASS_THRESHOLD)
    replies = await ask(true);
  let rows: Array<{ section: number | null; row: Row }> = replies.flatMap((reply, at) =>
    reply.sections.flatMap((section) =>
      section.rows.map((row) => ({
        section: section.sectionIndex,
        row: { ...row, index: row.index + runs[at]!.start },
      })),
    ),
  );
  if (typed) {
    rows.sort((a, b) => b.row.score - a.row.score || a.row.index - b.row.index);
    rows = rows.slice(0, ROW_LIMIT);
    rows.forEach((item, rank) => {
      if (rank >= HIGHLIGHT_LIMIT) item.row.highlights = [];
    });
  }
  // Sections in the order their first row comes; in section order when the request keeps it (the
  // empty query always does).
  const bySection = new Map<number | null, Row[]>();
  for (const { section, row } of rows) {
    let list = bySection.get(section);
    if (!list) bySection.set(section, (list = []));
    list.push(row);
  }
  const order = [...bySection.keys()];
  if (!typed || bounded.keepsSectionOrder) order.sort((a, b) => (a ?? -1) - (b ?? -1));
  return { sections: order.map((sectionIndex) => ({ sectionIndex, rows: bySection.get(sectionIndex)! })) };
}

/**
 * A fixture ranker, NOT the palette's ranking: the rows in their order, kept when the title or a
 * keyword contains the query (case-insensitive), grouped by section. The gallery and the mock
 * provider answer with it, and so does a daemon too old to have `palette.rank`. On the empty
 * query it gives what the shared ranker gives for these rows (their order by section), so the
 * palette's first frame matches the daemon's answer.
 */
export function fixtureRank(request: PaletteRankRequest): PaletteRankReply {
  const query = request.query.trim().toLowerCase();
  const bySection = new Map<number, PaletteRankedSection["rows"]>();
  request.entries.forEach((entry, index) => {
    const words = [entry.title, ...(entry.keywords ?? [])];
    if (query ? !words.some((word) => word.toLowerCase().includes(query)) : entry.isVisibleWhenQueryEmpty === false)
      return;
    const section = entry.sectionIndex ?? 0;
    let rows = bySection.get(section);
    if (!rows) bySection.set(section, (rows = []));
    rows.push({ index, score: 0, highlights: [] });
  });
  return {
    sections: [...bySection.entries()]
      .sort(([a], [b]) => a - b)
      .map(([sectionIndex, rows]) => ({ sectionIndex, rows })),
  };
}
