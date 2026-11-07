// The Bookmarks page's state owner on the page side: the profile, the tree, the shown folder, the
// search, the selection and the editor. The tree is a projection of the daemon's store
// (`cmux.bookmarks.*`); the page keeps no optimistic copy: every change is one
// `cmux.bookmarks.apply` from the person's click or key, then a re-list. React reads it through
// `useSyncExternalStore`.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import {
  buildTree,
  childrenOf,
  deleteOps,
  dropInto,
  dropOnRow,
  editorOps,
  editState,
  iconKey,
  isRoot,
  moveOps,
  rangeSelection,
  type EditorState,
  type RootTitles,
  type Tree,
} from "./model";
import {
  ACTION_RUN,
  BookmarkActions,
  BookmarkOps,
  CLIPBOARD_WRITE,
  HostOps,
  type Bookmark,
  type BookmarkOp,
  type ChangedEvent,
  type Disposition,
  type HostChangedEvent,
  type IconsResult,
  type ListResult,
  type RefusalExtra,
  type SearchResult,
  type StateResult,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export interface Notice {
  kind: "failed";
  message: string;
  code?: string;
}

/** The open editor: its fields, and a refusal said inline. */
export interface OpenEditor extends EditorState {
  error?: { kind: "invalidURL" } | { kind: "refused"; message: string };
}

export interface RowIcon {
  src: string;
  /** A template symbol: drawn in the row's text color. */
  mask: boolean;
}

export interface BookmarksSnapshot {
  connection: Connection;
  /** True until the first listing arrives. */
  loading: boolean;
  profile: string;
  titles: RootTitles;
  canSetFolderIcons: boolean;
  revision: number;
  tree: Tree;
  /** The folder the list shows when there is no search. */
  folder: string;
  text: string;
  /** The search's rows; null when the field is empty. */
  results: Bookmark[] | null;
  /** What the list shows: the search's rows, else the folder's children. */
  rows: readonly Bookmark[];
  /** The selected ids, in the order they were picked. */
  selection: readonly string[];
  /** The row Up/Down moves from. */
  focus?: string;
  /** The row Shift-click and Shift-Up/Down extend from. */
  anchor?: string;
  /** Collapsed folders of the left tree. */
  collapsed: ReadonlySet<string>;
  /** Favicons and folder icons by `iconKey`; null for a row the host has no icon for (yet). */
  icons: Readonly<Record<string, RowIcon | null>>;
  editor?: OpenEditor;
  notice?: Notice;
}

export interface BookmarksStoreOptions {
  newKey?: () => string;
  /** The default name of a new folder (`folder.new`). */
  newFolderTitle?: string;
  /** A reveal asked before the tree arrived was shown (the page drops its `#/?reveal=` route). */
  onRevealed?: (id: string) => void;
  /** Said when a selection needs more ops than one apply takes (`page.tooMany`). */
  tooManyMessage?: string;
}

const EMPTY_TREE = buildTree([]);

export class BookmarksStore {
  private snapshot: BookmarksSnapshot;
  private readonly listeners = new Set<() => void>();
  private stateGeneration = 0;
  private generation = 0;
  private searchGeneration = 0;
  private stops: Array<() => void> = [];
  private started = false;
  /** The change subscriptions, from the first ask until one fails or the page stops. */
  private changes?: Promise<void>;
  /** Bumped by `stop()`, so a subscription still in flight can tell it is stale. */
  private epoch = 0;
  /** Icon keys asked for and not answered yet. */
  private readonly asking = new Set<string>();
  /** The editor's last unanswered save (its reply was lost): a retry of the same ops reuses its
   * idempotency key, so the daemon replays it instead of making a second bookmark. */
  private unanswered?: { ops: string; key: string };
  private saving = false;
  /** A `reveal` of a node the tree does not hold yet. */
  private pendingReveal?: string;

  constructor(
    private readonly client: PageClient | null,
    private readonly options: BookmarksStoreOptions = {},
  ) {
    this.snapshot = {
      connection: client ? "connecting" : "disconnected",
      loading: client !== null,
      profile: "default",
      titles: { bar: "", other: "" },
      canSetFolderIcons: false,
      revision: -1,
      tree: EMPTY_TREE,
      folder: "bar",
      text: "",
      results: null,
      rows: [],
      selection: [],
      collapsed: new Set(),
      icons: {},
    };
  }

  getSnapshot = (): BookmarksSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Subscribes to the page streams and the change streams, then loads. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.started) return;
    this.started = true;
    try {
      // The link events first: a start whose change subscription fails while the host is gone
      // still hears the link come back and finishes then (`resume`).
      this.stops.push(
        await subscribePageStreams(this.client, { onConnection: (connected) => this.onConnection(connected) }),
      );
      await this.followChanges(this.client);
    } catch (error) {
      this.set({ loading: false, ...failure(error) });
      // Without the link events nothing hears a reconnect: a later start() begins clean.
      if (this.stops.length === 0) this.started = false;
      return;
    }
    if (!this.started) {
      this.stop();
      return;
    }
    await this.reload();
  }

  /** Follows `cmux.bookmarks.changed` and `cmux.bookmarkPage.changed`; one subscription each,
   * however many starts and reconnects ask. */
  private followChanges(client: PageClient): Promise<void> {
    if (this.changes) return this.changes;
    const epoch = this.epoch;
    const subscribing = (async () => {
      const stops = [
        await client.subscribe<ChangedEvent>(BookmarkOps.changed, (event) => {
          const { profile, revision } = this.snapshot;
          if (event.browser_profile_id === profile && event.bookmarks_revision > revision) void this.relist();
        }),
        await client.subscribe<HostChangedEvent>(HostOps.changed, (event) => {
          if (event?.reason === "icons") this.forgetMissingIcons();
          else void this.reload();
        }),
      ];
      // The page stopped (or stopped and started) while this was in flight: they are not this run's.
      if (epoch !== this.epoch || !this.started) return stops.forEach((stop) => stop());
      this.stops.push(...stops);
    })();
    this.changes = subscribing;
    // A failed subscription is not kept: the next start or reconnect asks again.
    subscribing.catch(() => {
      if (this.changes === subscribing) this.changes = undefined;
    });
    return subscribing;
  }

  stop(): void {
    this.started = false;
    this.epoch += 1;
    this.changes = undefined;
    for (const stop of this.stops) stop();
    this.stops = [];
  }

  private onConnection(connected: boolean): void {
    if (!connected) {
      this.set({ connection: "disconnected", loading: false });
    } else if (this.snapshot.connection === "disconnected") {
      this.set({ connection: "connecting" });
      void this.resume();
    }
  }

  /** The link came back: follow the changes if the start could not, then read the tree. */
  private async resume(): Promise<void> {
    if (!this.client) return;
    try {
      await this.followChanges(this.client);
    } catch (error) {
      this.set({ loading: false, ...failure(error) });
      return;
    }
    await this.reload();
  }

  /** Reads the profile and root titles, then the tree. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.stateGeneration;
    let state: StateResult;
    try {
      state = await this.client.call<StateResult>(HostOps.state, {});
    } catch (error) {
      if (generation === this.stateGeneration) this.set({ loading: false, ...failure(error) });
      return;
    }
    if (generation !== this.stateGeneration) return;
    const profile = state.browser_profile_id;
    const switched = profile !== this.snapshot.profile;
    this.set({
      profile,
      titles: { bar: state.bar_title, other: state.other_title },
      canSetFolderIcons: state.can_set_folder_icons,
      ...(switched ? { folder: "bar", selection: [], focus: undefined, editor: undefined, revision: -1 } : {}),
    });
    await this.relist();
  }

  /** Re-reads the tree of the page's profile (a change, an apply). */
  async relist(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const listing = await this.client.call<ListResult>(BookmarkOps.list, {
        browser_profile_id: this.snapshot.profile,
      });
      if (generation !== this.generation) return;
      this.take(listing);
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
    }
  }

  private take(listing: ListResult): void {
    const tree = buildTree(listing.bookmarks);
    const { folder, selection, focus } = this.snapshot;
    // A shown folder that went away (deleted elsewhere) falls back to the bar.
    const shown = isRoot(folder) || tree.nodes.has(folder) ? folder : "bar";
    this.set({
      connection: "connected",
      loading: false,
      revision: listing.bookmarks_revision,
      tree,
      folder: shown,
      selection: selection.filter((id) => tree.nodes.has(id)),
      focus: focus !== undefined && tree.nodes.has(focus) ? focus : undefined,
    });
    const pending = this.pendingReveal;
    if (pending !== undefined && tree.nodes.has(pending)) {
      this.reveal(pending);
      this.options.onRevealed?.(pending);
    } else if (this.snapshot.text.trim()) void this.search(this.snapshot.text);
  }

  // Search. Every keystroke asks the daemon; a reply older than the newest ask is dropped.

  setText(text: string): void {
    if (text === this.snapshot.text) return;
    if (!text.trim()) {
      this.searchGeneration += 1;
      this.set({ text, results: null });
      return;
    }
    this.set({ text });
    void this.search(text);
  }

  private async search(text: string): Promise<void> {
    if (!this.client) return;
    const generation = ++this.searchGeneration;
    try {
      const reply = await this.client.call<SearchResult>(BookmarkOps.search, {
        browser_profile_id: this.snapshot.profile,
        text,
      });
      if (generation !== this.searchGeneration) return;
      const results = reply.bookmarks;
      const shown = new Set(results.map((row) => row.id));
      this.set({ results, selection: this.snapshot.selection.filter((id) => shown.has(id)) });
    } catch (error) {
      if (generation !== this.searchGeneration) return;
      this.set(failure(error));
    }
  }

  /** The `reset` page command. */
  resetQuery(): void {
    this.searchGeneration += 1;
    this.set({ text: "", results: null, editor: undefined });
  }

  // Navigation and selection.

  showFolder(folder: string): void {
    this.searchGeneration += 1;
    this.set({ folder, text: "", results: null, selection: [], focus: undefined, anchor: undefined });
  }

  setCollapsed(folder: string, collapsed: boolean): void {
    if (this.snapshot.collapsed.has(folder) === collapsed) return;
    const next = new Set(this.snapshot.collapsed);
    if (collapsed) next.add(folder);
    else next.delete(folder);
    this.set({ collapsed: next });
  }

  /** A click or arrow: `single` replaces the selection, `toggle` (Cmd-click) flips one, `range`
   * (Shift) selects from the anchor to `id`. */
  select(id: string | undefined, how: "single" | "toggle" | "range" = "single"): void {
    if (id === undefined) {
      this.set({ selection: [], focus: undefined, anchor: undefined });
      return;
    }
    const { selection, anchor, rows } = this.snapshot;
    if (how === "toggle") {
      const next = selection.includes(id) ? selection.filter((other) => other !== id) : [...selection, id];
      this.set({ selection: next, focus: id, anchor: id });
    } else if (how === "range") {
      this.set({ selection: rangeSelection(rows, anchor ?? id, id), focus: id, anchor: anchor ?? id });
    } else {
      this.set({ selection: [id], focus: id, anchor: id });
    }
  }

  /** Show in Folder and the `reveal` page command: clear the search, show the node's folder,
   * select it and scroll to it. */
  reveal(id: string): void {
    const node = this.snapshot.tree.nodes.get(id);
    // Asked before the tree arrived (the page opened to reveal it): shown with the first listing.
    this.pendingReveal = node ? undefined : id;
    if (!node) return;
    this.searchGeneration += 1;
    this.set({ text: "", results: null, folder: node.parent, selection: [id], focus: id, anchor: id });
  }

  dismissNotice(): void {
    if (this.snapshot.notice) this.set({ notice: undefined });
  }

  // Opening. Return or a double-click opens a bookmark and enters a folder.

  activate(node: Bookmark): void {
    if (node.kind === "folder") this.showFolder(node.id);
    else void this.open(node, "current");
  }

  async open(node: Bookmark, disposition: Disposition): Promise<void> {
    await this.host(HostOps.open, { bookmark: node.id, ...(node.url ? { url: node.url } : {}), disposition });
  }

  async openAll(folder: Bookmark): Promise<void> {
    await this.host(HostOps.openAll, { folder: folder.id });
  }

  async copyURL(node: Bookmark): Promise<void> {
    if (node.url) await this.host(CLIPBOARD_WRITE, { text: node.url });
  }

  // The editor.

  /** Where an add goes: the shown folder, or the bar while searching. */
  private addFolder(): string {
    return this.snapshot.text.trim() ? "bar" : this.snapshot.folder;
  }

  startAddBookmark(): void {
    this.unanswered = undefined;
    this.set({
      editor: { mode: { kind: "addBookmark" }, isFolder: false, title: "", url: "", folder: this.addFolder() },
    });
  }

  startAddFolder(): void {
    const title = this.options.newFolderTitle ?? "";
    this.unanswered = undefined;
    this.set({ editor: { mode: { kind: "addFolder" }, isFolder: true, title, url: "", folder: this.addFolder() } });
  }

  startEdit(node: Bookmark): void {
    this.unanswered = undefined;
    this.set({ editor: editState(node) });
  }

  setEditor(patch: Partial<Pick<EditorState, "title" | "url" | "folder">>): void {
    const editor = this.snapshot.editor;
    if (editor) this.set({ editor: { ...editor, ...patch, error: undefined } });
  }

  cancelEditor(): void {
    if (this.snapshot.editor) this.set({ editor: undefined });
  }

  /** Save (Return): one apply; an invalid URL or a refusal keeps the editor open and says why.
   * A second Save while one is in flight does nothing. */
  async commitEditor(): Promise<boolean> {
    const editor = this.snapshot.editor;
    if (!editor || this.saving) return false;
    const plan = editorOps(this.snapshot.tree, this.snapshot.profile, editor);
    if (!plan.ok) {
      this.set({ editor: { ...editor, error: { kind: "invalidURL" } } });
      return false;
    }
    if (plan.ops.length > 0) {
      const ops = JSON.stringify(plan.ops);
      const key = this.unanswered?.ops === ops ? this.unanswered.key : this.key();
      this.saving = true;
      let refusal: Notice | null;
      try {
        refusal = await this.apply(plan.ops, false, key, (lost) => {
          this.unanswered = lost ? { ops, key } : undefined;
        });
      } finally {
        this.saving = false;
      }
      if (refusal) {
        // The editor may have closed (Escape) while the apply was in flight.
        const still = this.snapshot.editor;
        if (still) this.set({ editor: { ...still, error: { kind: "refused", message: refusal.message } } });
        else this.set({ notice: refusal });
        return false;
      }
    }
    this.set({ editor: undefined });
    return true;
  }

  // Changes. Each is one apply, called only from the person's click or key.

  async deleteSelection(ids: readonly string[] = this.snapshot.selection): Promise<void> {
    const ops = deleteOps(this.snapshot.tree, ids);
    if (ops.length === 0 || this.tooMany(ops.length)) return;
    const gone = new Set(ids);
    this.set({ selection: this.snapshot.selection.filter((id) => !gone.has(id)) });
    await this.apply(ops);
  }

  /** The dragged rows dropped on a list row: before it, or into it when it is a folder. */
  async dropOnRow(dragged: readonly string[], target: Bookmark): Promise<void> {
    const place = dropOnRow(this.snapshot.tree, dragged, target);
    if (place) await this.move(dragged, place);
  }

  /** The dragged rows dropped on a folder (a tree row, a breadcrumb): at its end. */
  async dropInto(dragged: readonly string[], folder: string): Promise<void> {
    const place = dropInto(this.snapshot.tree, dragged, folder);
    if (place) await this.move(dragged, place);
  }

  private async move(dragged: readonly string[], place: { parent: string; index: number }): Promise<void> {
    const ops = moveOps(this.snapshot.tree, dragged, place);
    if (ops.length > 0 && !this.tooMany(ops.length)) await this.apply(ops);
  }

  /** One apply takes at most `MAX_APPLY_OPS` ops (the daemon's bound): a larger selection is
   * said, not sent. */
  private tooMany(count: number): boolean {
    if (count <= MAX_APPLY_OPS) return false;
    this.set({
      notice: { kind: "failed", message: this.options.tooManyMessage ?? `Select at most ${MAX_APPLY_OPS} items.` },
    });
    return true;
  }

  // Native steps: the app's file panels, its browser import sheet and its icon picker.

  async importFile(): Promise<void> {
    await this.runAction({ action: BookmarkActions.import, args: { profile: this.snapshot.profile } });
  }

  async importFromBrowser(): Promise<void> {
    await this.runAction({ action: BookmarkActions.importFromBrowser, args: { profile: this.snapshot.profile } });
  }

  async exportFile(): Promise<void> {
    await this.runAction({ action: BookmarkActions.export, args: { profile: this.snapshot.profile } });
  }

  async setIcon(folder: Bookmark): Promise<void> {
    await this.runAction({ action: BookmarkActions.setIcon, target: `bookmark:${folder.id}` });
  }

  async clearIcon(folder: Bookmark): Promise<void> {
    await this.runAction({ action: BookmarkActions.clearIcon, target: `bookmark:${folder.id}` });
  }

  // Icons: asked for the rows on screen only, cached by id, favicon and folder icon.

  async requestIcons(nodes: readonly Bookmark[]): Promise<void> {
    if (!this.client) return;
    const wanted = nodes.filter((node) => {
      const key = iconKey(node);
      return !(key in this.snapshot.icons) && !this.asking.has(key);
    });
    if (wanted.length === 0) return;
    const keys = wanted.map(iconKey);
    for (const key of keys) this.asking.add(key);
    try {
      const reply = await this.client.call<IconsResult>(HostOps.icons, { ids: wanted.map((node) => node.id) });
      const masks = new Set(reply.masks ?? []);
      const icons = { ...this.snapshot.icons };
      // An id without an icon is cached as null so the row keeps its placeholder and is not asked
      // again until the host says an icon landed.
      wanted.forEach((node, index) => {
        const src = reply.icons[node.id];
        icons[keys[index] ?? ""] = src ? { src, mask: masks.has(node.id) } : null;
      });
      this.set({ icons });
    } catch {
      // A missing icon keeps the placeholder; the next scroll asks again.
    } finally {
      for (const key of keys) this.asking.delete(key);
    }
  }

  /** A favicon or folder icon landed: the rows without one ask again on the next render. */
  private forgetMissingIcons(): void {
    const icons = Object.fromEntries(Object.entries(this.snapshot.icons).filter(([, icon]) => icon !== null));
    this.set({ icons });
  }

  /** One `cmux.bookmarks.apply`, then a re-list. Returns the refusal, or null. `answered` hears
   * whether the reply was lost (the link closed or the call failed outside the page protocol):
   * then the ops may have run. */
  private async apply(
    ops: BookmarkOp[],
    report = true,
    key = this.key(),
    answered?: (lost: boolean) => void,
  ): Promise<Notice | null> {
    if (!this.client) return null;
    try {
      await this.client.call(BookmarkOps.apply, { ops, idempotency_key: key });
      answered?.(false);
    } catch (error) {
      const refusal = noticeOf(error);
      const lost = !isPageError(error) || error.code === LINK_CLOSED;
      answered?.(lost);
      if (isPageError(error) && error.code === LINK_CLOSED) this.set({ connection: "disconnected" });
      else if (report) this.set({ notice: refusal });
      // Ops before a refusal stay applied (`details.extra.applied`): the tree is re-read either way.
      void this.relist();
      return refusal;
    }
    if (this.snapshot.notice) this.set({ notice: undefined });
    // The daemon also sends `cmux.bookmarks.changed`; re-reading keeps the page right when it is late.
    await this.relist();
    return null;
  }

  private async runAction(params: Record<string, unknown>): Promise<void> {
    await this.host(ACTION_RUN, params);
  }

  /** A host step that changes no bookmark itself (open, copy, a native sheet). */
  private async host(op: string, params: Record<string, unknown>): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(op, params);
    } catch (error) {
      this.set(failure(error));
      return;
    }
    if (this.snapshot.notice) this.set({ notice: undefined });
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<BookmarksSnapshot>): void {
    const next = { ...this.snapshot, ...patch };
    if ("tree" in patch || "folder" in patch || "results" in patch) {
      next.rows = next.results ?? childrenOf(next.tree, next.folder);
    }
    this.snapshot = next;
    for (const listener of this.listeners) listener();
  }
}

/** Most ops one `cmux.bookmarks.apply` takes (the daemon's `MAX_OPS`). */
export const MAX_APPLY_OPS = 256;

function noticeOf(error: unknown): Notice {
  const message = error instanceof Error ? error.message : String(error);
  const extra = isPageError(error) ? refusalExtra(error.details) : undefined;
  return { kind: "failed", message, ...(extra?.code ? { code: extra.code } : {}) };
}

function refusalExtra(details: unknown): RefusalExtra | undefined {
  if (typeof details !== "object" || details === null) return undefined;
  const extra = (details as { extra?: unknown }).extra;
  return typeof extra === "object" && extra !== null ? (extra as RefusalExtra) : undefined;
}

function failure(error: unknown): Partial<BookmarksSnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected" };
  return { notice: noticeOf(error) };
}
