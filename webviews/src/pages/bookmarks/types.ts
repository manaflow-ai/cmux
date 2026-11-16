// Wire types of the Bookmarks page (`cmux-page://cmux.bookmarks/`). The tree is the daemon's
// routed `bookmarks.*` namespace (cmux-tui-core server/bookmarks_routed.rs), reached through the
// page relay; the app serves only what needs it (`cmux.bookmarkPage.*`: the profile and root
// titles, favicons, opening a page) and its native steps (`cmux.app.*`). The mock provider
// (mockProvider.ts) serves the same contract.

export const BookmarkOps = {
  /** `{browser_profile_id}` → `{bookmarks_revision, bookmarks}` in listing order. */
  list: "cmux.bookmarks.list",
  /** `{browser_profile_id, text, limit?}` → `{bookmarks}`: nodes whose title or URL holds every term. */
  search: "cmux.bookmarks.search",
  /** `{ops, idempotency_key}` → `{results}`; one person's action is one apply. */
  apply: "cmux.bookmarks.apply",
  /** Stream `{browser_profile_id, bookmarks_revision}`. */
  changed: "cmux.bookmarks.changed",
} as const;

export const HostOps = {
  /** `{}` → `{browser_profile_id, bar_title, other_title, can_set_folder_icons}`. */
  state: "cmux.bookmarkPage.state",
  /** Stream `{reason}`: `state` (the profile changed: re-read the state, then the tree) or `icons`
   * (a favicon or folder icon landed: ask again for the missing ones). */
  changed: "cmux.bookmarkPage.changed",
  /** `{ids}` → `{icons: {id: dataURL}, masks: [id]}`: favicons and folder icons of the rows on
   * screen; an id in `masks` is a symbol the page tints. */
  icons: "cmux.bookmarkPage.icons",
  /** `{bookmark, url?, disposition}`: `url` is the row as the page shows it. */
  open: "cmux.bookmarkPage.open",
  /** `{folder}`: every URL bookmark directly in the folder, in new tabs. */
  openAll: "cmux.bookmarkPage.openAll",
} as const;

/** The host's native op that runs one of the page's registry actions. */
export const ACTION_RUN = "cmux.app.action.run";
export const CLIPBOARD_WRITE = "cmux.app.clipboard.write";

/** The registry actions the page runs (`cmux.app.action.run {action, args?, target?}`). */
export const BookmarkActions = {
  import: "bookmark.import",
  importFromBrowser: "bookmark.importFromBrowser",
  export: "bookmark.export",
  setIcon: "bookmark.setIcon",
  clearIcon: "bookmark.clearIcon",
} as const;

/** The two fixed roots; a node's `parent` is one of them or a folder's id. */
export const ROOTS = ["bar", "other"] as const;
export type RootId = (typeof ROOTS)[number];

export type BookmarkKind = "url" | "folder";

export interface Bookmark {
  id: string;
  browser_profile_id: string;
  parent: string;
  kind: BookmarkKind;
  index: number;
  title: string;
  url?: string | null;
  favicon_key?: string | null;
  source_key?: string | null;
  created_ms: number;
  last_used_ms?: number | null;
  /** A folder's own icon (set with bookmark.setIcon). */
  icon?: string | null;
}

export interface ListResult {
  bookmarks_revision: number;
  bookmarks: Bookmark[];
}

export interface SearchResult {
  bookmarks: Bookmark[];
}

export interface ChangedEvent {
  browser_profile_id: string;
  bookmarks_revision: number;
}

export interface StateResult {
  browser_profile_id: string;
  bar_title: string;
  other_title: string;
  can_set_folder_icons: boolean;
}

export interface IconsResult {
  icons: Record<string, string>;
  /** Ids whose icon is a template symbol drawn in the text color. */
  masks?: string[];
}

export interface HostChangedEvent {
  reason?: "state" | "icons";
}

export type Disposition = "current" | "newTab" | "backgroundTab";

/** One op of `cmux.bookmarks.apply`, the daemon's `BookmarkOp` shape. */
export type BookmarkOp =
  | {
      op: "create";
      id: null;
      browser_profile_id: string;
      parent: string;
      index: number | null;
      kind: BookmarkKind;
      title: string;
      url?: string;
      favicon_key: null;
      source_key: null;
      created_ms: null;
    }
  | { op: "update"; bookmark: string; title?: string; url?: string }
  /** `index` is the final position among the destination's children. */
  | { op: "move"; bookmark: string; parent: string; index: number }
  | { op: "delete"; bookmark: string };

/** A refusal's `details.extra` (`code` is `bookmarks.<rule>`). */
export interface RefusalExtra {
  code?: string;
  reason?: string;
  applied?: number;
}
