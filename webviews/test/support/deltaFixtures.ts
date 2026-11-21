// Fixtures at Leo's scale for the delta-read detectors and bench/page-delta-reads.bench.ts: a
// History of 1,000 entries (the page's first window) and a Feed of up to 2,000 items (the daemon's
// view cap), with a stand-in daemon for each that answers as the real one does.
import type { HistoryEntry, HistoryKind } from "../../src/pages/history/types";
import type { FeedView, ViewItem } from "../../src/pages/feed/types";

const KINDS: HistoryKind[] = ["page", "command", "agent", "location", "closed"];

export function historyEntries(count = 1000): HistoryEntry[] {
  return Array.from({ length: count }, (_, index) => {
    const kind = KINDS[index % KINDS.length];
    return {
      id: `${kind}:local/${index}`,
      kind,
      at_ms: 1_790_000_000_000 - index * 60_000,
      title: `${kind} ${index}: a title as long as a real page or command line`,
      detail: `/Users/someone/Projects/repo-${index % 40}/src/module-${index}`,
      available: true,
      ...(kind === "command" ? { command: `cargo test -p crate-${index}`, exit_code: 0 } : {}),
      ...(kind === "agent" ? { provider: "claude", session_id: `sess-${index}`, running: index % 7 === 0 } : {}),
    };
  });
}

/** The daemon's `history.entries.list`: the entries of the asked kinds, newest first. */
export function historyAnswer(entries: HistoryEntry[]) {
  return (op: string, params: unknown) => {
    if (op !== "cmux.history.entries.list") return {};
    const kinds = (params as { kinds?: HistoryKind[] }).kinds ?? [];
    const shown = kinds.length ? entries.filter((entry) => kinds.includes(entry.kind)) : entries;
    return { entries: shown, revision: "1" };
  };
}

export function feedItem(index: number, revision = 1): ViewItem {
  return {
    id: `fi_${String(index).padStart(20, "0")}`,
    home: "cloud",
    kind: "notice",
    title: `Build ${index} finished (revision ${revision})`,
    body: "All 214 checks passed on the branch; the preview is ready to open.",
    poster: { kind: "agent", label: "CI" },
    state: "open",
    created_at: 1_790_000_000_000 - index * 60_000,
    revision,
    pending: false,
    row: {
      headline: `Build ${index} finished`,
      detail: "All 214 checks passed",
      detail_is_code: false,
      who: "Claude Code",
      where: "cmux › feed-perf",
      icon: "terminal",
      urgent: false,
      dimmed: false,
      local: false,
    },
  };
}

/** The daemon's feed client for the List layout: one `rest` group, newest first, honouring a delta
 * read's `only` as feed-core's view.rs does (every other item `{id, same: true}`). */
export class FeedDaemon {
  items: ViewItem[];
  revision = 1;

  constructor(count = 2000) {
    this.items = Array.from({ length: count }, (_, index) => feedItem(index));
  }

  touch(index: number): string {
    this.revision += 1;
    this.items[index] = feedItem(index, this.revision);
    return this.items[index].id;
  }

  answer = (op: string, params: unknown) => {
    if (op !== "cmux.feed.view.read") return {};
    const only = (params as { only?: string[] }).only;
    const wanted = only ? new Set(only) : undefined;
    const item = (value: ViewItem) => (wanted && !wanted.has(value.id) ? { id: value.id, same: true } : value);
    const view = {
      revision: this.revision,
      loaded: true,
      account: { id: "acct", user: "me" },
      connection: { state: "connected" },
      counts: { open_requests: 0, unread_notices: 0, badge: 0, unread: 0 },
      github: { enabled: false },
      reports: { available: false },
      groups: [
        { id: "requests", entries: [] },
        {
          id: "rest",
          entries: this.items.map((value) => ({ id: value.id, item: item(value), members: [], unread: false })),
        },
      ],
      total: this.items.length,
    };
    return view as unknown as FeedView;
  };
}
