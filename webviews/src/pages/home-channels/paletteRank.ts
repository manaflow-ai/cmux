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

// The daemon's caps (`palette.rank` in resource-operations-v2.json) count UTF-8 bytes; a UTF-16
// unit is at most 3 bytes, so these lengths always fit.
/** Most rows one request carries. */
export const MAX_RANK_ENTRIES = 5000;
const MAX_TITLE = 170;
const MAX_KEYWORDS = 32;
const MAX_KEYWORD = 85;
const MAX_QUERY = 340;

/** The request clipped to the daemon's caps, so a long title or a big list never fails the rank. */
export function boundedRankRequest(request: PaletteRankRequest): PaletteRankRequest {
  return {
    ...request,
    query: request.query.slice(0, MAX_QUERY),
    entries: request.entries.slice(0, MAX_RANK_ENTRIES).map((entry) => ({
      ...entry,
      title: entry.title.slice(0, MAX_TITLE),
      keywords: entry.keywords?.slice(0, MAX_KEYWORDS).map((keyword) => keyword.slice(0, MAX_KEYWORD)),
    })),
  };
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
