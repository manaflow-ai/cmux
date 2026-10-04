// An in-memory `cmux.history` provider for the browser dev loop and tests. It is not the backend:
// the daemon module (cmux-tui/crates/cmux-history) owns filtering, retention and clearing. The mock
// keeps only enough of it (kinds, search tokens, range, remove, clear) to drive the page.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import {
  ACTION_RUN,
  CLIPBOARD_WRITE,
  HistoryOps,
  type HistoryChanged,
  type HistoryEntry,
  type HistoryListParams,
  type HistoryListResult,
  type HistoryRange,
} from "./types";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** Case, diacritic and width insensitive, like the Swift and Rust folds. */
export function fold(text: string): string {
  return text.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase("en");
}

function searchText(entry: HistoryEntry): string {
  return [
    entry.title,
    entry.detail,
    entry.machine,
    entry.url,
    entry.workspace,
    entry.cwd,
    entry.command,
    entry.provider,
    entry.session_id,
  ]
    .filter(Boolean)
    .join(" ");
}

function rangeStart(range: HistoryRange | undefined, now: number): number | undefined {
  switch (range ?? "all") {
    case "hour":
      return now - HOUR;
    case "today": {
      const date = new Date(now);
      return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    }
    case "week":
      return now - 7 * DAY;
    case "month":
      return now - 28 * DAY;
    case "all":
      return undefined;
  }
}

export interface MockCall {
  op: string;
  params: unknown;
}

export class MockHistoryProvider implements PageClient {
  entries: HistoryEntry[];
  readonly calls: MockCall[] = [];
  private revision = 1;
  private nextSub = 1;
  private readonly subs = new Map<number, (data: unknown, seq: number) => void>();
  private readonly seqs = new Map<number, number>();
  private readonly handlers = new Map<string, PageHandler>();
  /** Set to make every call reject as if the host went away. */
  offline = false;

  constructor(
    entries: HistoryEntry[] = sampleEntries(Date.now()),
    private readonly now: () => number = Date.now,
  ) {
    this.entries = entries;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError("cmux.protocol.transport", "disconnected", true);
    switch (op) {
      case HistoryOps.list:
        return this.list(params as HistoryListParams) as R;
      case HistoryOps.remove: {
        const ids = new Set((params as { ids: string[] }).ids);
        return this.mutate((entry) => !ids.has(entry.id), ["page", "location", "closed", "command", "agent"]) as R;
      }
      case HistoryOps.removeSite: {
        const { host } = params as { host: string };
        return this.mutate((entry) => entry.kind !== "page" || !entry.url || hostOf(entry.url) !== host, ["page"]) as R;
      }
      case HistoryOps.clear: {
        const start = rangeStart((params as { range: HistoryRange }).range, this.now());
        return this.mutate(
          (entry) => start !== undefined && entry.at_ms < start,
          ["page", "location", "closed", "command", "agent"],
        ) as R;
      }
      case ACTION_RUN:
      case CLIPBOARD_WRITE:
        return { ok: true } as R;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (this.offline) throw pageError("cmux.protocol.transport", "disconnected", true);
    if (stream !== HistoryOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    const sub = this.nextSub++;
    this.subs.set(sub, onEvent as (data: unknown, seq: number) => void);
    return () => {
      this.subs.delete(sub);
    };
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => this.handlers.delete(op);
  }

  /** Host to page call (the dispatcher's `find` command in the dev loop). */
  invoke(op: string, params: unknown): unknown {
    return this.handlers.get(op)?.(params);
  }

  get subscriberCount(): number {
    return this.subs.size;
  }

  /** Adds an entry as the owner would after a new fact, and notifies. */
  push(entry: HistoryEntry): void {
    this.entries = [entry, ...this.entries];
    this.emit({ revision: ++this.revision, kinds: [entry.kind] });
  }

  private list(params: HistoryListParams): HistoryListResult {
    const kinds = new Set(params.kinds ?? []);
    const tokens = (params.text ?? "").split(/\s+/).filter(Boolean).map(fold);
    const start = rangeStart(params.range, this.now());
    const matched = this.entries
      .filter((entry) => kinds.size === 0 || kinds.has(entry.kind))
      .filter((entry) => start === undefined || entry.at_ms >= start)
      .filter((entry) => {
        const haystack = fold(searchText(entry));
        return tokens.every((token) => haystack.includes(token));
      })
      .sort((a, b) => b.at_ms - a.at_ms || (a.id < b.id ? 1 : -1));
    return { entries: matched.slice(0, params.limit ?? 200), revision: this.revision };
  }

  private mutate(keep: (entry: HistoryEntry) => boolean, kinds: HistoryChanged["kinds"]): { removed: number } {
    const before = this.entries.length;
    this.entries = this.entries.filter(keep);
    const removed = before - this.entries.length;
    if (removed) this.emit({ revision: ++this.revision, kinds });
    return { removed };
  }

  private emit(event: HistoryChanged): void {
    for (const [sub, listener] of this.subs) {
      const seq = (this.seqs.get(sub) ?? 0) + 1;
      this.seqs.set(sub, seq);
      listener(event, seq);
    }
  }
}

function hostOf(url: string): string | undefined {
  try {
    return new URL(url).hostname;
  } catch {
    return undefined;
  }
}

/** Sample data across every kind and three days, for the dev loop. */
export function sampleEntries(now: number): HistoryEntry[] {
  const at = (hoursAgo: number) => now - hoursAgo * HOUR;
  return [
    {
      id: "page:default:1",
      kind: "page",
      at_ms: at(0.2),
      title: "manaflow-ai/cmux: pull requests",
      detail: "https://github.com/manaflow-ai/cmux/pulls",
      url: "https://github.com/manaflow-ai/cmux/pulls",
      profile: "default",
      available: true,
    },
    {
      id: "location:home:t1",
      kind: "location",
      at_ms: at(0.3),
      title: "zsh",
      detail: "cmux-next",
      workspace: "cmux-next",
      available: true,
      current: true,
    },
    {
      id: "agent:home:s1",
      kind: "agent",
      at_ms: at(0.5),
      title: "Claude Code",
      detail: "~/fun/cmux",
      workspace: "cmux-next",
      cwd: "~/fun/cmux",
      session_id: "4f1c2d7e-claude",
      provider: "claude",
      available: true,
      running: true,
    },
    {
      id: "command:home:c1",
      kind: "command",
      at_ms: at(0.8),
      title: "bun test",
      detail: "~/fun/cmux/webviews",
      cwd: "~/fun/cmux/webviews",
      command: "bun test",
      exit_code: 0,
      available: true,
    },
    {
      id: "closed:home:x1",
      kind: "closed",
      at_ms: at(1.2),
      title: "Résumé draft",
      detail: "https://example.com/resume",
      url: "https://example.com/resume",
      closed_kind: "browser_tab",
      workspace: "notes",
      available: true,
    },
    {
      id: "page:default:2",
      kind: "page",
      at_ms: at(2),
      title: "Rust std::collections",
      detail: "https://doc.rust-lang.org/std/collections/",
      url: "https://doc.rust-lang.org/std/collections/",
      profile: "default",
      available: true,
    },
    {
      id: "agent:mini:s2",
      kind: "agent",
      at_ms: at(5),
      title: "Codex",
      detail: "~/work/api",
      machine: "build-mini",
      cwd: "~/work/api",
      session_id: "codex-7781",
      provider: "codex",
      available: false,
    },
    {
      id: "command:mini:c2",
      kind: "command",
      at_ms: at(26),
      title: "cargo test -p cmux-history",
      detail: "~/work/cmux",
      machine: "build-mini",
      cwd: "~/work/cmux",
      command: "cargo test -p cmux-history",
      exit_code: 101,
      available: false,
    },
    {
      id: "page:default:3",
      kind: "page",
      at_ms: at(27),
      title: "GitHub",
      detail: "https://github.com/",
      url: "https://github.com/",
      profile: "default",
      available: true,
    },
    {
      id: "location:home:t2",
      kind: "location",
      at_ms: at(30),
      title: "api server",
      detail: "backend",
      workspace: "backend",
      available: true,
    },
    {
      id: "closed:home:x2",
      kind: "closed",
      at_ms: at(50),
      title: "backend",
      closed_kind: "workspace",
      workspace: "backend",
      available: true,
    },
    {
      id: "page:work:4",
      kind: "page",
      at_ms: at(52),
      title: "Linear: cmux-next board",
      detail: "https://linear.app/cmux/board",
      url: "https://linear.app/cmux/board",
      profile: "work",
      available: true,
    },
  ];
}
