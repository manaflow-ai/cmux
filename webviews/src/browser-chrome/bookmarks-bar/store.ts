// The bookmarks bar's state owner on the page side (pages/bookmarks-bar). The bar reads only what
// it draws: the bar root's own children and whether Other Bookmarks holds anything, with one
// `cmux.bookmarks.children` each, again on every `cmux.bookmarks.changed` of its profile (and on a
// relay resync). A folder menu reads the folder's subtree on its click. Every change is one
// `cmux.bookmarksBar.apply` from the person's drag or drop, written by the app (its copy of the tree
// and the last folder follow, as for the star). The app serves the profile, the icons and opening
// (`cmux.bookmarkPage.*`), and the native menus, layout reports and writes (`cmux.bookmarksBar.*`).
import { isPageError, type PageClient } from "../../pages/shared/pageClient";
import { subscribePageStreams } from "../../pages/shared/pageStreams";
import { iconKey } from "../../pages/bookmarks/model";
import {
  BookmarkOps,
  HostOps,
  type Bookmark,
  type BookmarkOp,
  type Disposition,
  type HostChangedEvent,
  type IconsResult,
  type StateResult,
} from "../../pages/bookmarks/types";
import { createOnBar, groupChildren, menuRows, moveOnBar, type MenuRow, type MenuWords } from "./model";

export const BarOps = {
  /** `{browser_profile_id, parent, depth?, limit?}` → `{bookmarks_revision, bookmarks, total, truncated}`. */
  children: "cmux.bookmarks.children",
  /** `{profile, lend, title, anchor: {x, y, width, height}, rows}`: the host pops a native menu
   * under `anchor` and opens what the person picks there; it drops one for a profile or lend it left. */
  menu: "cmux.bookmarksBar.menu",
  /** `{bookmark?, point: {x, y}}`: the registry's Bookmark (or Bookmarks Bar) menu at `point`. */
  contextMenu: "cmux.bookmarksBar.contextMenu",
  /** `{visible: [{id, title, x, width}], overflow: [title]}` after each layout: the host's
   * diagnostics, the icon picker's anchor, and the first one shows the bar. */
  layout: "cmux.bookmarksBar.layout",
  /** `{op}`: one create or move on the bar, written by the app on the person's gesture. */
  apply: "cmux.bookmarksBar.apply",
  /** `{message}`: the owner refused a drop or a move; the app says why (its refusal toast). */
  refused: "cmux.bookmarksBar.refused",
} as const;

/** Most rows one folder menu reads (`MAX_CHILDREN_LIMIT` in bookmarks_routed.rs). */
export const MENU_LIMIT = 20_000;
const MAX_DEPTH = 64;

interface ChildrenResult {
  bookmarks_revision: number;
  bookmarks: Bookmark[];
  total: number;
  truncated: boolean;
}

interface ChangedEvent {
  browser_profile_id?: string;
  bookmarks_revision?: number;
  /** The relay lost events or reconnected: re-read. */
  resync?: boolean;
}

export interface BarIcon {
  src: string;
  /** A template symbol drawn in the bar's icon color. */
  mask: boolean;
}

export interface BarSnapshot {
  /** The first read landed: the bar can draw its real row. */
  loaded: boolean;
  profile: string;
  otherTitle: string;
  /** The tree revision the bar's row was read at. */
  revision: number;
  /** The revision Other Bookmarks' count was read at: its own, since the two reads are separate. */
  otherRevision: number;
  items: readonly Bookmark[];
  hasOther: boolean;
  icons: Readonly<Record<string, BarIcon | null>>;
}

export interface Anchor {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface LaidOut {
  /** The profile whose row this is: a page lent to another profile's bar reports again even when
   * the row looks the same (two empty bars), and the host drops a report for a profile it left. */
  profile: string;
  visible: Array<{ id: string; title: string; x: number; width: number }>;
  overflow: string[];
}

const EMPTY: BarSnapshot = {
  loaded: false,
  profile: "default",
  otherTitle: "",
  revision: -1,
  otherRevision: -1,
  items: [],
  hasOther: false,
  icons: {},
};

export class BookmarksBarStore {
  private snapshot: BarSnapshot = EMPTY;
  private readonly listeners = new Set<() => void>();
  private stops: Array<() => void> = [];
  private started = false;
  /** The live `bookmarks.changed` subscription; null until it is made (again after a reconnect). */
  private following: (() => void) | null = null;
  private followingPending = false;
  /** Bumped by each stop: a subscription that lands after it is dropped. */
  private session = 0;
  /** Cancels a profile reload (`reload`) superseded by a newer one or a stop. */
  private profileGeneration = 0;
  /** The host's lend of this page (it moves between tabs): a menu read across a lend is dropped. */
  private lend: number | null = null;
  /** Cancels a row read (`read`) superseded by a newer one or a stop. A row read never cancels a
   * profile reload, so a change event during a tab switch cannot strand the bar on the old profile. */
  private generation = 0;
  private readonly asking = new Set<string>();

  constructor(
    private readonly client: PageClient | null,
    private readonly words: MenuWords,
  ) {}

  getSnapshot = (): BarSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  async start(): Promise<void> {
    const client = this.client;
    if (!client || this.started) return;
    this.started = true;
    const session = this.session;
    // The app's streams (connection, profile and icons) are local; the tree's changes come from the
    // daemon, so that subscription is made again on each reconnect until it holds.
    const onConnection = (connected: boolean) => {
      if (!connected) return;
      void this.follow();
      void this.reload();
    };
    for (const subscribe of [
      () => subscribePageStreams(client, { onConnection }),
      () =>
        client.subscribe<HostChangedEvent>(HostOps.changed, (event) => {
          if (typeof event?.lend === "number") this.lend = event.lend;
          if (event?.reason === "icons") this.forgetMissingIcons();
          else if (event?.reason !== "lend") void this.reload();
        }),
    ]) {
      try {
        const stop = await subscribe();
        if (session === this.session) this.stops.push(stop);
        else stop();
      } catch {
        // No live updates from it: the bar still reads.
      }
    }
    await this.follow();
    await this.reload();
  }

  /** Subscribes to the tree's changes unless that is already live or under way. */
  private async follow(): Promise<void> {
    const client = this.client;
    if (!client || !this.started || this.following || this.followingPending) return;
    const session = this.session;
    this.followingPending = true;
    try {
      const stop = await client.subscribe<ChangedEvent>(BookmarkOps.changed, (event) => {
        if (event?.resync) return void this.read();
        // Newer than either read: one of them may be stale, so both are read again.
        const { profile, revision, otherRevision } = this.snapshot;
        const changed = event?.bookmarks_revision ?? 0;
        if (event?.browser_profile_id === profile && (changed > revision || changed > otherRevision)) void this.read();
      });
      if (session === this.session) this.following = stop;
      else stop();
    } catch {
      // The daemon is away (or older): the next reconnect tries again.
    } finally {
      if (session === this.session) this.followingPending = false;
    }
  }

  stop(): void {
    this.started = false;
    this.session += 1;
    this.profileGeneration += 1;
    this.generation += 1;
    this.followingPending = false;
    this.following?.();
    this.following = null;
    for (const stop of this.stops) stop();
    this.stops = [];
  }

  /** Reads the profile (the tab the bar is in), then its row. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.profileGeneration;
    let state: StateResult;
    try {
      state = await this.client.call<StateResult>(HostOps.state, {});
    } catch {
      return;
    }
    if (generation !== this.profileGeneration) return;
    if (typeof state.lend === "number") this.lend = state.lend;
    if (state.browser_profile_id !== this.snapshot.profile) {
      // Another profile's row must not show for a frame: nothing until its own read lands.
      this.set({ ...EMPTY, profile: state.browser_profile_id, otherTitle: state.other_title });
    } else if (state.other_title !== this.snapshot.otherTitle) {
      this.set({ otherTitle: state.other_title });
    }
    await this.read();
  }

  /** Re-reads the bar's row and Other Bookmarks' count of the page's profile. */
  async read(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    const profile = this.snapshot.profile;
    try {
      const [bar, other] = await Promise.all([
        this.client.call<ChildrenResult>(BarOps.children, { browser_profile_id: profile, parent: "bar" }),
        this.client.call<ChildrenResult>(BarOps.children, { browser_profile_id: profile, parent: "other", limit: 0 }),
      ]);
      if (generation !== this.generation || profile !== this.snapshot.profile) return;
      this.set({
        loaded: true,
        revision: bar.bookmarks_revision,
        otherRevision: other.bookmarks_revision,
        items: bar.bookmarks,
        hasOther: other.total > 0,
      });
    } catch {
      // The row on screen stays; the next change or reconnect reads again.
    }
  }

  /** Asks the host for the icons of the items on screen it has not answered yet. */
  async requestIcons(nodes: readonly Bookmark[]): Promise<void> {
    if (!this.client) return;
    const wanted = nodes.filter((node) => !(iconKey(node) in this.snapshot.icons) && !this.asking.has(iconKey(node)));
    if (wanted.length === 0) return;
    const keys = wanted.map(iconKey);
    for (const key of keys) this.asking.add(key);
    try {
      const reply = await this.client.call<IconsResult>(HostOps.icons, { ids: wanted.map((node) => node.id) });
      const masks = new Set(reply.masks ?? []);
      const icons = { ...this.snapshot.icons };
      wanted.forEach((node, index) => {
        const src = reply.icons[node.id];
        icons[keys[index] ?? ""] = src ? { src, mask: masks.has(node.id) } : null;
      });
      this.set({ icons });
    } catch {
      // The stand-in stays; the next render asks again.
    } finally {
      for (const key of keys) this.asking.delete(key);
    }
  }

  private forgetMissingIcons(): void {
    this.set({ icons: Object.fromEntries(Object.entries(this.snapshot.icons).filter(([, icon]) => icon !== null)) });
  }

  /** Opens a link item from the person's click. */
  open(node: Bookmark, disposition: Disposition): void {
    void this.client
      ?.call(HostOps.open, { bookmark: node.id, url: node.url ?? undefined, disposition })
      // A refused open (no gesture behind it, an unknown bookmark) is not silent.
      .catch((error: unknown) => console.warn("cmux bookmarks bar: open refused", error));
  }

  /** A folder's native menu under `anchor`: its subtree read now, so the menu is the stored one. */
  async openFolder(folder: Bookmark, anchor: Anchor, title: string): Promise<void> {
    const read = await this.subtree(folder.id);
    if (!read) return;
    await this.showMenu(read, title, anchor, menuRows(read.groups, folder.id, this.words));
  }

  /** Other Bookmarks' menu. */
  async openOther(anchor: Anchor): Promise<void> {
    const read = await this.subtree("other");
    if (!read) return;
    await this.showMenu(read, this.snapshot.otherTitle, anchor, menuRows(read.groups, "other", this.words));
  }

  /** The chevron's menu: the bar items past the first `shown`, folders with their contents. The
   * bar's own row is read on its own beside the subtree, so a folder with more descendants than one
   * read's rows cannot starve the bar items after it out of the menu; only that folder's contents
   * are cut. */
  async openOverflow(shown: number, anchor: Anchor, title: string): Promise<void> {
    const read = await this.subtree("bar", true);
    if (!read) return;
    const hidden = (read.groups.get("bar") ?? []).slice(shown);
    await this.showMenu(read, title, anchor, menuRows(read.groups, null, this.words, hidden));
  }

  /** `parent`'s subtree in the bar's profile, or null when the read failed or the page moved to
   * another tab meanwhile (a lend, even to a tab of the same profile): its menu would act there.
   * With `ownRow`, `parent`'s direct children come from a separate one-level read, so a truncated
   * depth-first subtree never drops a later sibling. */
  private async subtree(
    parent: string,
    ownRow = false,
  ): Promise<{ profile: string; lend: number | null; groups: Map<string, Bookmark[]> } | null> {
    const client = this.client;
    if (!client) return null;
    const profile = this.snapshot.profile;
    const lend = this.lend;
    const children = (depth: number) =>
      client.call<ChildrenResult>(BarOps.children, { browser_profile_id: profile, parent, depth, limit: MENU_LIMIT });
    try {
      const [reply, row] = await Promise.all([children(MAX_DEPTH), ownRow ? children(1) : null]);
      if (this.snapshot.profile !== profile || this.lend !== lend) return null;
      const groups = groupChildren(reply.bookmarks);
      if (row) groups.set(parent, groupChildren(row.bookmarks).get(parent) ?? []);
      return { profile, lend, groups };
    } catch {
      return null;
    }
  }

  /** The host drops a menu for a profile or a lend it left (the page may not have heard yet). */
  private async showMenu(
    read: { profile: string; lend: number | null },
    title: string,
    anchor: Anchor,
    rows: MenuRow[],
  ): Promise<void> {
    const { profile, lend } = read;
    await this.client?.call(BarOps.menu, { profile, lend, title, anchor, rows }).catch(() => undefined);
  }

  contextMenu(bookmark: string | null, point: { x: number; y: number }): void {
    void this.client?.call(BarOps.contextMenu, { bookmark, point }).catch(() => undefined);
  }

  /** Reports what the bar shows (diagnostics, the icon picker's anchor; the first shows the bar). */
  report(laidOut: LaidOut): void {
    void this.client?.call(BarOps.layout, laidOut).catch(() => undefined);
  }

  /** A bar item dragged to slot `slot` of the bar. */
  async move(id: string, slot: number): Promise<void> {
    const op = moveOnBar(this.snapshot.items, id, slot);
    if (op) await this.apply(op);
  }

  /** A link dropped on the bar at `slot`. */
  async drop(url: string, title: string, slot: number): Promise<void> {
    await this.apply(createOnBar(this.snapshot.profile, url, title, slot));
  }

  private async apply(op: BookmarkOp): Promise<void> {
    if (!this.client || !this.snapshot.loaded) return;
    try {
      await this.client.call(BarOps.apply, { op });
    } catch (error) {
      // A refused drop or move says why, as the app's other refusals do; the row is read again.
      const message = isPageError(error) ? error.message : String(error);
      void this.client.call(BarOps.refused, { message }).catch(() => undefined);
    }
    void this.read();
  }

  private set(patch: Partial<BarSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}
