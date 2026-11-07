// A machine's folders, one directory at a time (acpmux `_acpmux/browse`), for the composer's folder
// browser (RemoteFolderBrowser.tsx). Only the directory shown is asked for, a page at a time; a
// directory left before its answer arrives drops that answer, so a slow machine never repaints a
// folder the person already moved away from.

export type BrowseKind = "dir" | "file" | "symlink" | "other";

/// One entry of a listing. A link is reported as a link with what it points at (`target`), never
/// followed by the listing; `outside`: it leads out of the folders the machine starts chats in.
export type BrowseEntry = {
  name: string;
  path: string;
  kind: BrowseKind;
  target?: "dir" | "file" | "missing";
  outside?: true;
  size?: number;
};

export type BrowseParams = {
  /// The acpmux peer that lists; none: the page's own daemon.
  peer?: string;
  /// None on a peer: the folders it starts chats in (its roots); on this daemon, home.
  path?: string;
  hidden?: boolean;
  dirsOnly?: boolean;
  offset?: number;
  limit?: number;
};

export type BrowseReply = {
  path: string | null;
  parent: string | null;
  home: string;
  roots?: string[];
  entries: BrowseEntry[];
  total: number;
  offset: number;
  nextOffset?: number;
  /// The machine stopped reading the directory: too many entries, or past its deadline.
  truncated?: { reason: "cap" | "deadline"; scanned: number };
  peer?: string;
};

export type BrowseFolders = (params: BrowseParams) => Promise<BrowseReply>;

/// Rows per request: a screenful many times over, and a bounded reply however big the directory.
export const BROWSE_PAGE = 200;
/// A machine that has not answered by then is told as unreachable; its late answer is dropped.
export const BROWSE_GIVE_UP_MS = 15_000;

/// Why a listing failed, as the browser says it.
export type BrowseFailure = "unsupported" | "outside" | "unreachable" | "failed";

export function browseFailure(error: unknown): BrowseFailure {
  const { code, reason } = (error ?? {}) as { code?: unknown; reason?: unknown };
  // An acpmux from before `_acpmux/browse`, on this Mac or on the peer.
  if (code === -32601 || code === "transport.method_refused" || code === "remote.unsupported") return "unsupported";
  if (reason === "browse.outside_roots") return "outside";
  if (reason === "peer_unreachable" || code === "native.not_connected" || reason === "browse.timeout")
    return "unreachable";
  return "failed";
}

/// A row the browser opens: a folder, or a link to one, inside the folders the machine allows.
export function opensAsFolder(entry: BrowseEntry): boolean {
  if (entry.outside) return false;
  return entry.kind === "dir" || (entry.kind === "symlink" && entry.target === "dir");
}

/// What the browser shows. `path` null: the machine's top (its roots on a peer).
export type BrowseView = {
  path: string | null;
  parent: string | null;
  home?: string;
  entries: BrowseEntry[];
  loading: boolean;
  loadingMore: boolean;
  /// The offset of the next page, while there is one.
  more?: number;
  truncated?: BrowseReply["truncated"];
  failure?: BrowseFailure;
};

const EMPTY: BrowseView = { path: null, parent: null, entries: [], loading: false, loadingMore: false };

/// One browser's listings. Every `open` starts a new generation; an answer for an older one, a
/// directory left or a browser closed, is dropped.
export class FolderBrowse {
  private generation = 0;
  view: BrowseView = EMPTY;

  constructor(
    private readonly list: BrowseFolders,
    private readonly peer: string | undefined,
    private readonly onChange: (view: BrowseView) => void,
    private readonly giveUpMs = BROWSE_GIVE_UP_MS,
  ) {}

  open(path: string | null): void {
    const generation = ++this.generation;
    // The path shows at once; its parent waits for the machine's answer (it knows the real one).
    this.set({ ...EMPTY, path, parent: null, loading: true });
    this.ask(path, 0).then(
      (reply) => {
        if (generation !== this.generation) return;
        this.set(viewOf(reply, []));
      },
      (error) => {
        if (generation !== this.generation) return;
        this.set({ ...EMPTY, path, loading: false, failure: browseFailure(error) });
      },
    );
  }

  /// The next page of the directory shown, once; a page that arrives after the person moved on is dropped.
  more(): void {
    const { more, loading, loadingMore, path } = this.view;
    if (more === undefined || loading || loadingMore) return;
    const generation = this.generation;
    this.set({ ...this.view, loadingMore: true });
    this.ask(path, more).then(
      (reply) => {
        if (generation !== this.generation) return;
        this.set(viewOf(reply, this.view.entries));
      },
      () => {
        if (generation !== this.generation) return;
        // The rows already shown stay; the end of the list is not offered again.
        this.set({ ...this.view, loadingMore: false, more: undefined, truncated: this.view.truncated });
      },
    );
  }

  /// Closed: every answer still out is dropped.
  dispose(): void {
    this.generation += 1;
  }

  private ask(path: string | null, offset: number): Promise<BrowseReply> {
    const params: BrowseParams = {
      ...(this.peer ? { peer: this.peer } : {}),
      ...(path ? { path } : {}),
      dirsOnly: true,
      limit: BROWSE_PAGE,
      ...(offset ? { offset } : {}),
    };
    return new Promise<BrowseReply>((resolve, reject) => {
      const timer = setTimeout(() => reject({ reason: "browse.timeout" }), this.giveUpMs);
      this.list(params).then(
        (reply) => {
          clearTimeout(timer);
          resolve(reply);
        },
        (error: unknown) => {
          clearTimeout(timer);
          reject(error);
        },
      );
    });
  }

  private set(view: BrowseView): void {
    this.view = view;
    this.onChange(view);
  }
}

function viewOf(reply: BrowseReply, before: BrowseEntry[]): BrowseView {
  const entries = Array.isArray(reply.entries) ? reply.entries : [];
  return {
    path: reply.path ?? null,
    parent: reply.parent ?? null,
    home: reply.home,
    entries: before.length ? [...before, ...entries] : entries,
    loading: false,
    loadingMore: false,
    ...(typeof reply.nextOffset === "number" && entries.length > 0 ? { more: reply.nextOffset } : {}),
    ...(reply.truncated ? { truncated: reply.truncated } : {}),
  };
}

/// The breadcrumb of `path`: each folder from the top, `~` for the home folder when the path is in it.
export function browseCrumbs(path: string, home?: string): { name: string; path: string }[] {
  const crumbs: { name: string; path: string }[] = [];
  let rest = path;
  if (home && home !== "/" && (path === home || path.startsWith(home + "/"))) {
    crumbs.push({ name: "~", path: home });
    rest = path.slice(home.length);
  } else crumbs.push({ name: "/", path: "/" });
  let at = crumbs[0]!.path === "/" ? "" : crumbs[0]!.path;
  for (const name of rest.split("/").filter(Boolean)) {
    at += "/" + name;
    crumbs.push({ name, path: at });
  }
  return crumbs;
}
