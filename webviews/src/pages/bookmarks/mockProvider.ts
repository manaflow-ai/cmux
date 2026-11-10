// l10n-allow-file: mock fixtures (sample bookmark titles and root titles), not shipped UI.
// An in-memory bookmarks provider for the browser dev loop (`/bookmarks/?mock`), the gallery and
// tests. It is not the backend: the daemon's routed `bookmarks.*` owns the tree and its rules and
// the app owns the gesture gate. The mock keeps the same op contract and the refusals the page
// shows (a move into itself, a missing node, an op without the person's gesture).
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import {
  ACTION_RUN,
  BookmarkOps,
  CLIPBOARD_WRITE,
  HostOps,
  type Bookmark,
  type BookmarkOp,
  type ChangedEvent,
  type StateResult,
} from "./types";

export interface MockCall {
  op: string;
  params: Record<string, unknown>;
}

const NOW = Date.UTC(2026, 9, 1);
const PROFILE = "default";

/** A small tree: two folders on the bar (one nested), a few links, and Other Bookmarks. */
export function sampleBookmarks(): Bookmark[] {
  let next = 0;
  const node = (parent: string, kind: Bookmark["kind"], title: string, url?: string, extra: Partial<Bookmark> = {}) => {
    const id = `bm_${String(++next).padStart(32, "0")}`;
    return {
      id,
      browser_profile_id: PROFILE,
      parent,
      kind,
      index: 0,
      title,
      ...(url ? { url, favicon_key: new URL(url).origin } : {}),
      created_ms: NOW - next * 60_000,
      ...extra,
    } satisfies Bookmark;
  };
  const work = node("bar", "folder", "Work");
  const docs = node(work.id, "folder", "Docs");
  const reading = node("bar", "folder", "Reading");
  const listing = [
    work,
    node("bar", "url", "GitHub", "https://github.com/"),
    reading,
    node("bar", "url", "", "https://news.ycombinator.com/"),
    node(work.id, "url", "Pull requests", "https://github.com/pulls"),
    docs,
    node(work.id, "url", "Linear", "https://linear.app/"),
    node(docs.id, "url", "Rust docs", "https://doc.rust-lang.org/std/"),
    node(docs.id, "url", "MDN Web Docs", "https://developer.mozilla.org/"),
    node(reading.id, "url", "The Rust Programming Language", "https://doc.rust-lang.org/book/"),
    node("other", "url", "Local dev server", "http://localhost:3000/"),
    node("other", "url", "Example Domain", "https://example.com/"),
  ];
  return reindex(listing);
}

/** `count` links in one folder on the bar: the list virtualizes them. */
export function longBookmarks(count = 2_000): Bookmark[] {
  const folder: Bookmark = {
    id: "bm_long",
    browser_profile_id: PROFILE,
    parent: "bar",
    kind: "folder",
    index: 0,
    title: "Archive",
    created_ms: NOW,
  };
  const links = Array.from({ length: count }, (_, index): Bookmark => {
    const url = `https://site-${index + 1}.example/`;
    return {
      id: `bm_long_${index}`,
      browser_profile_id: PROFILE,
      parent: folder.id,
      kind: "url",
      index,
      title: `Saved page ${index + 1}`,
      url,
      favicon_key: new URL(url).origin,
      created_ms: NOW - index,
    };
  });
  return [folder, ...links];
}

/** Each node's index is its position among the listing's siblings. */
function reindex(listing: Bookmark[]): Bookmark[] {
  const counts = new Map<string, number>();
  return listing.map((node) => {
    const index = counts.get(node.parent) ?? 0;
    counts.set(node.parent, index + 1);
    return { ...node, index };
  });
}

export interface MockOptions {
  /** The host link is down from the start. */
  disconnected?: boolean;
  /** Every apply is refused with this rule (`bookmarks.<code>`). */
  refuse?: { code: string; message: string };
  canSetFolderIcons?: boolean;
}

export class MockBookmarksProvider implements PageClient {
  readonly calls: MockCall[] = [];
  readonly streams = new MockPageStreams();
  /** The person's click or key reached the page (the app's gesture record). */
  gesture = true;
  revision = 1;
  copied: string[] = [];
  opened: Array<{ bookmark: string; disposition: string }> = [];
  private nodes: Bookmark[];
  private readonly changed = new Set<(data: unknown, seq: number) => void>();
  private readonly hostChanged = new Set<(data: unknown, seq: number) => void>();
  private seq = 0;
  private created = 0;
  private readonly replies = new Map<string, unknown>();

  constructor(
    listing: Bookmark[] = sampleBookmarks(),
    private readonly options: MockOptions = {},
  ) {
    this.nodes = listing.map((node) => ({ ...node }));
    if (options.disconnected) this.streams.setConnected(false);
  }

  get listing(): readonly Bookmark[] {
    return this.nodes;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    const p = (params ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params: p });
    if (this.options.disconnected) throw pageError("cmux.protocol.closed", "The link is closed.");
    const key = typeof p.idempotency_key === "string" ? p.idempotency_key : undefined;
    if (key && this.replies.has(key)) return this.replies.get(key) as R;
    const value = this.answer(op, p);
    if (key) this.replies.set(key, value);
    return value as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const page = this.streams.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (page) return page;
    if (stream === HostOps.changed) {
      const listener = onEvent as (data: unknown, seq: number) => void;
      this.hostChanged.add(listener);
      return () => void this.hostChanged.delete(listener);
    }
    if (stream !== BookmarkOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    const listener = onEvent as (data: unknown, seq: number) => void;
    this.changed.add(listener);
    return () => void this.changed.delete(listener);
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }

  /** Another writer changed the tree (the bar, the CLI). */
  emitChanged(): void {
    const event: ChangedEvent = { browser_profile_id: PROFILE, bookmarks_revision: ++this.revision };
    for (const listener of this.changed) listener(event, ++this.seq);
  }

  /** The app's `cmux.bookmarkPage.changed`: the profile changed, or an icon landed. */
  emitHostChanged(reason: "state" | "icons"): void {
    for (const listener of this.hostChanged) listener({ reason }, ++this.seq);
  }

  private answer(op: string, p: Record<string, unknown>): unknown {
    switch (op) {
      case HostOps.state:
        return {
          browser_profile_id: PROFILE,
          bar_title: "Bookmarks Bar",
          other_title: "Other Bookmarks",
          can_set_folder_icons: this.options.canSetFolderIcons ?? true,
        } satisfies StateResult;
      case BookmarkOps.list:
        return { bookmarks_revision: this.revision, bookmarks: this.ordered() };
      case BookmarkOps.search: {
        const terms = String(p.text ?? "")
          .toLowerCase()
          .split(/\s+/)
          .filter(Boolean);
        const found = this.ordered().filter((node) => {
          const text = `${node.title} ${node.url ?? ""}`.toLowerCase();
          return terms.every((term) => text.includes(term));
        });
        return { bookmarks: found.slice(0, typeof p.limit === "number" ? p.limit : 1000) };
      }
      case BookmarkOps.apply:
        return this.apply(Array.isArray(p.ops) ? (p.ops as BookmarkOp[]) : []);
      case HostOps.icons:
        // The mock has no favicons: every row keeps its reserved placeholder.
        return { icons: {} };
      case HostOps.open:
        this.gate();
        this.opened.push({ bookmark: String(p.bookmark), disposition: String(p.disposition) });
        return {};
      case HostOps.openAll:
        this.gate();
        return { opened: this.nodes.filter((node) => node.parent === p.folder && node.kind === "url").length };
      case CLIPBOARD_WRITE:
        this.copied.push(String(p.text ?? ""));
        return {};
      case ACTION_RUN:
        this.gate();
        return { ran: true };
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  private apply(ops: BookmarkOp[]): unknown {
    this.gate();
    const results: unknown[] = [];
    ops.forEach((op, applied) => {
      const refuse = (code: string, message: string) => {
        if (applied > 0) this.changedNow();
        throw pageError("operation.failed", message, false, { extra: { code: `bookmarks.${code}`, applied } });
      };
      if (this.options.refuse) refuse(this.options.refuse.code, this.options.refuse.message);
      if (op.op === "create") {
        const id = `bm_new_${++this.created}`;
        const siblings = this.childrenOf(op.parent);
        this.nodes.push({
          id,
          browser_profile_id: op.browser_profile_id,
          parent: op.parent,
          kind: op.kind,
          index: op.index ?? siblings.length,
          title: op.title,
          ...(op.url ? { url: op.url } : {}),
          created_ms: NOW,
        });
        this.place(id, op.parent, op.index ?? siblings.length);
        results.push({ id });
        return;
      }
      const node = this.nodes.find((candidate) => candidate.id === op.bookmark);
      if (!node) return refuse("not_found", "This bookmark is no longer saved.");
      if (op.op === "update") {
        if (op.title !== undefined) node.title = op.title;
        if (op.url !== undefined) node.url = op.url;
      } else if (op.op === "move") {
        if (this.within(op.parent, node.id)) return refuse("invalid_params", "A folder cannot move into itself.");
        this.place(node.id, op.parent, op.index);
      } else {
        const gone = new Set(this.nodes.filter((other) => this.within(other.id, node.id)).map((other) => other.id));
        this.nodes = this.nodes.filter((other) => !gone.has(other.id));
        this.renumber(node.parent);
      }
      results.push({ id: node.id });
    });
    if (ops.length > 0) this.changedNow();
    return { results };
  }

  private changedNow(): void {
    this.revision += 1;
    const event: ChangedEvent = { browser_profile_id: PROFILE, bookmarks_revision: this.revision };
    for (const listener of this.changed) listener(event, ++this.seq);
  }

  private gate(): void {
    if (!this.gesture) throw pageError("cmux.app.user_only", "Only you can do this.");
  }

  private within(id: string, ancestor: string): boolean {
    for (let current: string | undefined = id; current; current = this.nodes.find((n) => n.id === current)?.parent) {
      if (current === ancestor) return true;
    }
    return false;
  }

  private childrenOf(parent: string): Bookmark[] {
    return this.nodes.filter((node) => node.parent === parent).sort((a, b) => a.index - b.index);
  }

  /** Puts `id` at `index` among `parent`'s children and renumbers both folders. */
  private place(id: string, parent: string, index: number): void {
    const node = this.nodes.find((candidate) => candidate.id === id);
    if (!node) return;
    const from = node.parent;
    const siblings = this.childrenOf(parent).filter((other) => other.id !== id);
    siblings.splice(Math.max(0, Math.min(index, siblings.length)), 0, node);
    node.parent = parent;
    siblings.forEach((sibling, position) => (sibling.index = position));
    if (from !== parent) this.renumber(from);
  }

  private renumber(parent: string): void {
    this.childrenOf(parent).forEach((node, position) => (node.index = position));
  }

  /** The listing in tree order (depth first), as `list-bookmarks` returns it. */
  private ordered(): Bookmark[] {
    const result: Bookmark[] = [];
    const visit = (parent: string) => {
      for (const node of this.childrenOf(parent)) {
        result.push({ ...node });
        if (node.kind === "folder") visit(node.id);
      }
    };
    visit("bar");
    visit("other");
    return result;
  }
}
