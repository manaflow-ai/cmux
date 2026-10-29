// The App Store page's state on the page side: a projection of the app supervisor
// (`cmux.apps.catalog.list`, `installed.list`, `grants.get`, `logs`, `asset.get`) plus view state
// (tab, query, category, selection). No optimistic copy: every mutation re-reads after the owner
// answers, and install, uninstall, update and grant changes go through the host's native
// confirmation (coordinator Q4), so the page shows the owner's result, never its own guess.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import {
  decodeFile,
  fromDetail,
  listCatalog,
  listInstalled,
  listUpdates,
  type DecodedFile,
  type WireDetail,
} from "./wire";
import {
  categories,
  filterApps,
  listedInStore,
  parseRoute,
  type CardStyle,
  type StoreLayout,
  type StoreTab,
} from "./model";
import {
  AppsOps,
  OPEN_ACTION,
  type AppDetail,
  type AppIconRef,
  type AppUpdate,
  type AppsChanged,
  type CatalogApp,
  type Grants,
  type InstalledApp,
  type LogLine,
  REJECT_REASON,
  RegistryOps,
  SIGNED_OUT,
  type RegistryListing,
  type RegistryListingsResult,
  type RegistryMe,
  type RegistrySubmission,
  type RegistrySubmissionsResult,
  type ReviewDecision,
  type ReviewFileResult,
  type ReviewQueueResult,
  type ReviewSubmission,
  type WireAsset,
  type WireLogs,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export type CatalogStatus = "loading" | "ready" | "error";
export type DetailStatus = "idle" | "loading" | "ready" | "not-found" | "error";

/** A registry read: `unavailable` when this host has no registry ops, `signed-out` without Cloud. */
export type RegistryStatus = "idle" | "loading" | "ready" | "error" | "signed-out" | "unavailable";

/** The community registry as the page sees it (custom-panes-DESIGN.md 6.4); the Cloud owns it. */
export interface RegistrySnapshot {
  me?: RegistryMe;
  listings: RegistryListing[];
  listingsStatus: RegistryStatus;
  listingsError?: string;
  submissions: RegistrySubmission[];
  submissionsStatus: RegistryStatus;
  submissionsError?: string;
  queue: ReviewSubmission[];
  queueStatus: RegistryStatus;
  queueError?: string;
  /** The app a Get or a submit is in flight for, or the submission a decision is in flight for. */
  busy?: string;
  /** The installed local app whose Submit for Review form is open. */
  submitFor?: string;
  /** The review queue's selected submission and its open file. */
  reviewSelection?: string;
  reviewFile?: { id: string; path: string; status: "loading" | "ready" | "error"; file?: DecodedFile; error?: string };
  /** A client-side refusal on the review form (reject without a reason). */
  reviewFormError?: string;
}

export interface AppsSnapshot {
  tab: StoreTab;
  layout: StoreLayout;
  /** The Discover card style (`card=`); `standard` unless a DEV route asks for another. */
  card: CardStyle;
  query: string;
  category?: string;
  catalog: CatalogApp[];
  /** The catalog filtered by query and category. */
  visible: CatalogApp[];
  categories: string[];
  installed: InstalledApp[];
  /** Updates reported by the supervisor. This may be stale when updates.list is unavailable. */
  updates: AppUpdate[];
  updatesLoading: boolean;
  updatesStale: boolean;
  updatesError?: string;
  updatesRevision?: number;
  selection?: string;
  detail?: AppDetail;
  grants: Record<string, Grants>;
  /** Installed row panels. */
  grantsShown?: string;
  logsShown?: string;
  logs: Record<string, LogLine[]>;
  loading: boolean;
  /** The catalog request state; stale rows remain visible while a retry is in flight. */
  catalogStatus: CatalogStatus;
  catalogError?: string;
  /** The selected detail request state; selection is retained across failures and retries. */
  detailStatus: DetailStatus;
  detailError?: string;
  connection: Connection;
  error?: string;
  registry: RegistrySnapshot;
}

/** The registry before its first read, and for a snapshot built without one. */
export const NO_REGISTRY: RegistrySnapshot = {
  listings: [],
  listingsStatus: "idle",
  submissions: [],
  submissionsStatus: "idle",
  queue: [],
  queueStatus: "idle",
};

const LOG_LINES = 200;

/** The host's code for a declined native sheet: the person said no, which is not an error. */
const CANCELLED = "cmux.page.cancelled";

export class AppsStore {
  private snapshot: AppsSnapshot;
  private readonly listeners = new Set<() => void>();
  private unwatch?: () => void;
  private unpage?: () => void;
  /** Icon data URLs by `app\u0000asset`; a failed load is "" so it is not asked again. */
  private readonly icons = new Map<string, string>();
  private starting = false;
  private generation = 0;
  /** Monotonic token so a slower updates.list response cannot replace a newer one. */
  private updatesGeneration = 0;
  private detailGeneration = 0;
  /**
   * The idempotency key of each action still in flight or failed with a retryable error, by op and
   * params: the person's next try of the same action sends the same key, so a retry after a
   * timeout never installs or toggles twice. Success, a refusal or a declined sheet ends it.
   */
  private readonly pendingKeys = new Map<string, string>();

  constructor(
    private readonly client: PageClient | null,
    hash = "",
  ) {
    const route = parseRoute(hash);
    this.snapshot = {
      tab: route.tab,
      layout: route.layout,
      card: route.card,
      query: "",
      catalog: [],
      visible: [],
      categories: [],
      installed: [],
      updates: [],
      updatesLoading: client !== null,
      updatesStale: false,
      selection: route.app && listedInStore({ id: route.app }) ? route.app : undefined,
      catalogStatus: client ? "loading" : "ready",
      detailStatus: client && route.app && listedInStore({ id: route.app }) ? "loading" : "idle",
      grants: {},
      logs: {},
      loading: client !== null,
      connection: client ? "connecting" : "disconnected",
      registry: { ...NO_REGISTRY, listingsStatus: client ? "loading" : "idle" },
    };
  }

  getSnapshot = (): AppsSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Watches the owner and loads the first view. Idempotent, also while a start is in flight. */
  async start(): Promise<void> {
    if (!this.client || this.unwatch || this.starting) return;
    this.starting = true;
    try {
      const unwatch = await this.client.subscribe<AppsChanged>(AppsOps.watch, () => void this.reload());
      if (!this.starting) {
        unwatch();
        return;
      }
      this.unwatch = unwatch;
    } catch (error) {
      if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op")) {
        this.set({ connection: "disconnected", loading: false, error: message(error) });
        return;
      }
    } finally {
      this.starting = false;
    }
    try {
      this.unpage = await subscribePageStreams(this.client, {
        onConnection: (connected) => this.onConnection(connected),
      });
    } catch (error) {
      this.set(failure(error));
    }
    await Promise.all([this.reload(), this.loadRegistry()]);
  }

  /** The host reports the owner link: down shows the disconnected state; back up re-reads. */
  private onConnection(connected: boolean): void {
    if (!connected) {
      this.set({ connection: "disconnected", loading: false });
    } else if (this.snapshot.connection === "disconnected") {
      this.set({ connection: "connecting" });
      void this.reload();
      void this.loadRegistry();
    }
  }

  stop(): void {
    this.unpage?.();
    this.unpage = undefined;
    this.starting = false;
    this.unwatch?.();
    this.unwatch = undefined;
  }

  /** Re-reads the catalog, installed list, and update list owned by the supervisor. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    const updatesGeneration = ++this.updatesGeneration;
    this.set({ loading: true, catalogStatus: "loading", catalogError: undefined });
    try {
      const [catalog, installed, updateResponse] = await Promise.all([
        listCatalog(this.client),
        listInstalled(this.client),
        listUpdates(this.client)
          .then((result) => ({ result, error: undefined as unknown }))
          .catch((error: unknown) => ({ result: undefined, error })),
      ]);
      if (generation !== this.generation) return;
      const listed = catalog.apps.filter(listedInStore);
      // Installed rows carry no icon: they take their listing's.
      const iconOf = new Map(listed.map((app) => [app.id, app.icon]));
      const installedRows = installed.apps
        .filter(listedInStore)
        .map((app) => (app.icon || !iconOf.get(app.id) ? app : { ...app, icon: iconOf.get(app.id) }));
      const installedIds = new Set(installedRows.map((app) => app.id));
      const acceptUpdates = updatesGeneration === this.updatesGeneration;
      const updates = (
        acceptUpdates
          ? (updateResponse.result?.updates ?? installedRows.flatMap(updateFromInstalled))
          : this.snapshot.updates
      ).filter((update) => installedIds.has(update.app));
      const updatesByApp = new Map(updates.map((update) => [update.app, update]));
      const mergedInstalled = installedRows.map((app) => {
        const update = updatesByApp.get(app.id);
        if (!update) return app;
        return {
          ...app,
          update: { version: update.version },
          failure: update.failure ?? app.failure,
        };
      });
      this.set({
        catalog: listed,
        visible: filterApps(listed, this.snapshot.query, this.snapshot.category),
        categories: categories(listed),
        installed: mergedInstalled,
        updates,
        updatesLoading: acceptUpdates ? false : this.snapshot.updatesLoading,
        updatesStale: acceptUpdates ? !updateResponse.result : this.snapshot.updatesStale,
        updatesError: acceptUpdates
          ? updateResponse.error
            ? message(updateResponse.error)
            : undefined
          : this.snapshot.updatesError,
        updatesRevision: acceptUpdates
          ? (updateResponse.result?.revision ?? installed.revision)
          : this.snapshot.updatesRevision,
        loading: false,
        catalogStatus: "ready",
        catalogError: undefined,
        connection: "connected",
        error: undefined,
      });
      if (this.snapshot.selection) await this.loadDetail(this.snapshot.selection);
      if (this.snapshot.grantsShown) await this.loadGrants(this.snapshot.grantsShown);
      if (this.snapshot.logsShown) await this.loadLogs(this.snapshot.logsShown);
      this.showIcons();
      void this.loadIcons(generation);
    } catch (error) {
      if (generation !== this.generation) return;
      const failed = failure(error);
      this.set({
        loading: false,
        updatesLoading: false,
        catalogStatus: "error",
        catalogError: failed.error,
        // A deep-linked detail waits on the catalog; the banner's Reload retries both.
        ...(this.snapshot.detailStatus === "loading" ? { detailStatus: "error", detailError: failed.error } : {}),
        ...failed,
        error: undefined,
      });
    }
  }

  /** Re-reads only the update list without guessing at a new version after a failure. */
  async refreshUpdates(): Promise<void> {
    if (!this.client) return;
    const updatesGeneration = ++this.updatesGeneration;
    this.set({ updatesLoading: true });
    try {
      const result = await listUpdates(this.client);
      if (updatesGeneration !== this.updatesGeneration) return;
      const installedIds = new Set(this.snapshot.installed.map((app) => app.id));
      const updates = result.updates.filter((update) => installedIds.has(update.app));
      const updatesByApp = new Map(updates.map((update) => [update.app, update]));
      this.set({
        updates,
        updatesLoading: false,
        updatesStale: false,
        updatesError: undefined,
        updatesRevision: result.revision,
        installed: this.snapshot.installed.map((app) => {
          const update = updatesByApp.get(app.id);
          if (!update) return app.update ? { ...app, update: undefined, failure: undefined } : app;
          return { ...app, update: { version: update.version }, failure: update.failure ?? app.failure };
        }),
      });
    } catch (error) {
      if (updatesGeneration !== this.updatesGeneration) return;
      this.set({ updatesLoading: false, updatesStale: true, updatesError: message(error) });
    }
  }

  /** The host set a new fragment (`appStore.show {app}`, `showInstalled`): its tab and listing. */
  applyRoute(hash: string): void {
    const route = parseRoute(hash);
    this.setTab(route.tab);
    if (route.layout !== this.snapshot.layout) this.set({ layout: route.layout });
    if (route.card !== this.snapshot.card) this.set({ card: route.card });
    if (route.app !== this.snapshot.selection) void this.select(route.app);
  }

  setTab(tab: StoreTab): void {
    if (tab !== this.snapshot.tab)
      this.set({ tab, selection: this.snapshot.layout === "split" ? this.snapshot.selection : undefined });
  }

  setQuery(query: string): void {
    this.set({
      query,
      visible: filterApps(this.snapshot.catalog, query, this.snapshot.category),
    });
  }

  setCategory(category: string | undefined): void {
    const next = this.snapshot.category === category ? undefined : category;
    this.set({ category: next, visible: filterApps(this.snapshot.catalog, this.snapshot.query, next) });
  }

  async select(app: string | undefined): Promise<void> {
    if (app && !listedInStore({ id: app })) app = undefined;
    this.set({
      selection: app,
      detail: app === this.snapshot.detail?.id ? this.snapshot.detail : undefined,
      detailStatus: app ? "loading" : "idle",
      detailError: undefined,
    });
    if (app) await this.loadDetail(app);
  }

  private async loadDetail(app: string): Promise<void> {
    if (!this.client) return;
    const generation = ++this.detailGeneration;
    if (this.snapshot.selection === app) this.set({ detailStatus: "loading", detailError: undefined });
    try {
      const detail = fromDetail(await this.client.call<WireDetail>(AppsOps.catalogGet, { app }));
      if (generation === this.detailGeneration && this.snapshot.selection === app)
        this.set({
          detail: { ...detail, icon: this.withIcon(app, detail.icon) },
          detailStatus: "ready",
          detailError: undefined,
        });
      if (detail.installed) await this.loadGrants(app);
    } catch (error) {
      if (generation === this.detailGeneration && this.snapshot.selection === app) {
        const failed = failure(error);
        const notFound = isPageError(error) && error.code === "cmux.apps.not_found";
        this.set({
          detailStatus: notFound ? "not-found" : "error",
          detailError: failed.error,
          ...failed,
          error: undefined,
        });
      }
    }
  }

  /** Retries the selected app without dropping its route or list selection. */
  retryDetail(): Promise<void> {
    const app = this.snapshot.selection;
    return app ? this.loadDetail(app) : Promise.resolve();
  }

  private async loadGrants(app: string): Promise<void> {
    if (!this.client) return;
    try {
      const grants = await this.client.call<Grants>(AppsOps.grantsGet, { app });
      this.set({ grants: { ...this.snapshot.grants, [app]: grants } });
    } catch (error) {
      this.set(failure(error));
    }
  }

  async toggleGrants(app: string): Promise<void> {
    const shown = this.snapshot.grantsShown === app ? undefined : app;
    this.set({ grantsShown: shown });
    if (shown) await this.loadGrants(shown);
  }

  /** Shows or hides an installed app's logs: the owner's last lines, read again on each reload. */
  async toggleLogs(app: string): Promise<void> {
    const shown = this.snapshot.logsShown === app ? undefined : app;
    this.set({ logsShown: shown, logs: shown ? { ...this.snapshot.logs, [app]: [] } : this.snapshot.logs });
    if (shown) await this.loadLogs(shown);
  }

  private async loadLogs(app: string): Promise<void> {
    if (!this.client) return;
    try {
      const wire = await this.client.call<WireLogs>(AppsOps.logs, { app, limit: LOG_LINES });
      const lines: LogLine[] = wire.lines.map((line) => ({
        level: line.level,
        message: line.message,
        at_ms: line.ts_ms,
      }));
      if (this.snapshot.logsShown === app) this.set({ logs: { ...this.snapshot.logs, [app]: lines } });
    } catch (error) {
      this.set(failure(error));
    }
  }

  /** The icon with its data URL when the store loaded it. */
  private withIcon(app: string, icon: AppIconRef | undefined): AppIconRef | undefined {
    if (!icon?.asset) return icon;
    const url = this.icons.get(`${app}\u0000${icon.asset}`);
    return url ? { ...icon, path: url } : icon;
  }

  /** Puts the loaded icons on every row that shows one. */
  private showIcons(): void {
    const patch = <T extends { id: string; icon?: AppIconRef }>(app: T): T => {
      const icon = this.withIcon(app.id, app.icon);
      return icon === app.icon ? app : { ...app, icon };
    };
    const { catalog, visible, installed, detail } = this.snapshot;
    this.set({
      catalog: catalog.map(patch),
      visible: visible.map(patch),
      installed: installed.map(patch),
      detail: detail ? patch(detail) : detail,
    });
  }

  /** Loads the icons no earlier reload loaded (`cmux.apps.asset.get`), then shows them. */
  private async loadIcons(generation: number): Promise<void> {
    const client = this.client;
    if (!client) return;
    const wanted = this.snapshot.catalog.filter(
      (app) => app.icon?.asset && !this.icons.has(`${app.id}\u0000${app.icon.asset}`),
    );
    if (wanted.length === 0) return;
    await Promise.all(
      wanted.map(async (app) => {
        const asset = app.icon?.asset ?? "";
        try {
          const wire = await client.call<WireAsset>(AppsOps.assetGet, { app: app.id, path: asset });
          this.icons.set(`${app.id}\u0000${asset}`, wire.data_url.startsWith("data:image/") ? wire.data_url : "");
        } catch {
          // No icon is not an error: the generic glyph stays.
          this.icons.set(`${app.id}\u0000${asset}`, "");
        }
      }),
    );
    if (generation === this.generation) this.showIcons();
  }

  // Mutations. Install, uninstall, update and grant changes show a native confirmation in the
  // host; the page waits for the owner's answer and re-reads.

  install(app: string): Promise<void> {
    return this.intent(AppsOps.install, { app, grant_optional: false });
  }

  uninstall(app: string): Promise<void> {
    return this.intent(AppsOps.uninstall, { app });
  }

  update(app: string): Promise<void> {
    return this.intent(AppsOps.update, { app });
  }

  setEnabled(app: string, enabled: boolean): Promise<void> {
    return this.intent(AppsOps.set, { app, enabled });
  }

  /** Hides or shows an app in the app areas; the only way to put a first-party app away. It needs
   * only the person's click (page-router.json `gesture`), never a sheet. */
  setHidden(app: string, hidden: boolean): Promise<void> {
    return this.intent(AppsOps.hiddenSet, { app, hidden });
  }

  setSandboxed(app: string, sandboxed: boolean): Promise<void> {
    return this.intent(AppsOps.set, { app, sandboxed });
  }

  /** Allowing a scope asks on the host's native sheet; revoking needs only the person's click. */
  setGranted(app: string, scope: string, granted: boolean): Promise<void> {
    return granted
      ? this.intent(AppsOps.grantSet, { app, scope, granted })
      : this.intent(AppsOps.grantRevoke, { app, scope });
  }

  /** Opens the app's page: the host action `app.open` (a host verb, not a daemon op). */
  open(app: string): Promise<void> {
    return this.intent(
      OPEN_ACTION.op,
      { action: OPEN_ACTION.action, args: { app } },
      { reread: false, mutation: false },
    );
  }

  private async intent(
    op: string,
    params: Record<string, unknown>,
    { reread = true, mutation = true }: { reread?: boolean; mutation?: boolean } = {},
  ): Promise<void> {
    if (!this.client) return;
    const action = `${op}\u0000${JSON.stringify(params)}`;
    let key = mutation ? this.pendingKeys.get(action) : undefined;
    if (mutation && !key) {
      key = newKey();
      this.pendingKeys.set(action, key);
    }
    try {
      await this.client.call(op, key ? { ...params, idempotency_key: key } : params);
      this.pendingKeys.delete(action);
      if (this.snapshot.error) this.set({ error: undefined });
    } catch (error) {
      if (!(isPageError(error) && error.retryable)) this.pendingKeys.delete(action);
      if (!(isPageError(error) && error.code === CANCELLED)) this.set(failure(error));
      return;
    }
    if (reread) await this.reload();
  }

  // The community registry. It is the Cloud's, not the supervisor's, so its reads are separate
  // from `reload` (a catalog change does not reread it) and one failing never hides the catalog.

  /** Reads who the person is, the approved listings, their submissions and, for a reviewer, the queue. */
  async loadRegistry(): Promise<void> {
    const client = this.client;
    if (!client) return;
    const [me, listings] = await Promise.all([
      client.call<RegistryMe>(RegistryOps.me, {}).then(
        (value) => ({ value, error: undefined as unknown }),
        (error: unknown) => ({ value: undefined, error }),
      ),
      this.readRegistryListings(client).then(
        (value) => ({ value, error: undefined as unknown }),
        (error: unknown) => ({ value: undefined, error }),
      ),
    ]);
    // A `me` that fails signed out is a signed-out person, not an error.
    const who: RegistryMe | undefined = me.value ?? (isCode(me.error, SIGNED_OUT) ? { signedIn: false } : undefined);
    const patch: Partial<RegistrySnapshot> = {
      me: who,
      listings: listings.value?.listings ?? [],
      listingsStatus: listings.value ? "ready" : registryStatus(listings.error),
      listingsError: listings.value ? undefined : message(listings.error),
    };
    if (!who?.signedIn) {
      patch.submissions = [];
      patch.submissionsStatus = who ? "signed-out" : registryStatus(me.error);
    }
    if (!who?.reviewer) {
      patch.queue = [];
      patch.queueStatus = "idle";
    }
    this.setRegistry(patch);
    await Promise.all([
      who?.signedIn ? this.loadSubmissions() : undefined,
      who?.reviewer ? this.loadQueue() : undefined,
    ]);
  }

  /** Follow the registry's cursor so search includes apps beyond its first page. */
  private async readRegistryListings(client: PageClient): Promise<RegistryListingsResult> {
    const listings: RegistryListingsResult["listings"] = [];
    const seen = new Set<string>();
    let cursor: string | undefined;
    for (;;) {
      const page = await client.call<RegistryListingsResult>(RegistryOps.listings, cursor ? { cursor } : {});
      listings.push(...page.listings);
      if (!page.cursor || seen.has(page.cursor)) return { listings };
      seen.add(page.cursor);
      cursor = page.cursor;
    }
  }

  private async loadSubmissions(): Promise<void> {
    if (!this.client) return;
    this.setRegistry({ submissionsStatus: "loading", submissionsError: undefined });
    try {
      const result = await this.client.call<RegistrySubmissionsResult>(RegistryOps.submissions, {});
      this.setRegistry({ submissions: result.submissions, submissionsStatus: "ready" });
    } catch (error) {
      this.setRegistry({ submissionsStatus: registryStatus(error), submissionsError: message(error) });
    }
  }

  private async loadQueue(): Promise<void> {
    if (!this.client) return;
    this.setRegistry({ queueStatus: "loading", queueError: undefined });
    try {
      const result = await this.client.call<ReviewQueueResult>(RegistryOps.reviewQueue, {});
      const selection = this.snapshot.registry.reviewSelection;
      const kept = result.submissions.some((item) => item.id === selection);
      this.setRegistry({
        queue: result.submissions,
        queueStatus: "ready",
        reviewSelection: kept ? selection : undefined,
        reviewFile: kept ? this.snapshot.registry.reviewFile : undefined,
      });
    } catch (error) {
      this.setRegistry({ queueStatus: registryStatus(error), queueError: message(error) });
    }
  }

  /**
   * Get: the host downloads the approved bundle and hands it to the daemon (`cmux.registry.get`),
   * then the ordinary install shows the native scopes sheet. A declined sheet is not an error.
   */
  async getListing(app: string, version: string): Promise<void> {
    if (!this.client || this.snapshot.registry.busy) return;
    this.setRegistry({ busy: app });
    try {
      await this.client.call(RegistryOps.get, { app, version });
    } catch (error) {
      this.setRegistry({ busy: undefined });
      if (!isCode(error, CANCELLED)) this.set(failure(error));
      return;
    }
    try {
      await this.intent(AppsOps.install, { app, grant_optional: false }, { reread: false });
    } finally {
      this.setRegistry({ busy: undefined });
    }
    // The app is in the catalog now, whether or not the person allowed the install.
    await this.reload();
  }

  /** Opens or closes the Submit for Review form of an installed local app. */
  toggleSubmit(app: string): void {
    this.setRegistry({ submitFor: this.snapshot.registry.submitFor === app ? undefined : app });
  }

  /** Submit for Review: the host shows its native confirmation first (publishing is outward-facing). */
  async submit(app: string, publisher: string, notes: string): Promise<void> {
    if (!this.client || this.snapshot.registry.busy) return;
    const params: Record<string, unknown> = { app, publisher: publisher.trim() };
    if (notes.trim()) params.notes = notes.trim();
    this.setRegistry({ busy: app });
    try {
      await this.client.call(RegistryOps.submit, params);
    } catch (error) {
      this.setRegistry({ busy: undefined });
      if (!isCode(error, CANCELLED)) this.set(failure(error));
      return;
    }
    this.setRegistry({ busy: undefined, submitFor: undefined });
    if (this.snapshot.error) this.set({ error: undefined });
    await this.loadSubmissions();
  }

  /** Selects a pending submission in the review queue; its files load on demand. */
  selectReview(id: string | undefined): void {
    if (id === this.snapshot.registry.reviewSelection) return;
    this.setRegistry({ reviewSelection: id, reviewFile: undefined, reviewFormError: undefined });
  }

  /** Reads one file of a pending submission (`cmux.registry.review.file`) to show it as text. */
  async openReviewFile(id: string, path: string): Promise<void> {
    if (!this.client) return;
    this.setRegistry({ reviewFile: { id, path, status: "loading" } });
    const current = () => {
      const open = this.snapshot.registry.reviewFile;
      return open?.id === id && open.path === path;
    };
    try {
      const result = await this.client.call<ReviewFileResult>(RegistryOps.reviewFile, { id, path });
      if (current()) this.setRegistry({ reviewFile: { id, path, status: "ready", file: decodeFile(result.base64) } });
    } catch (error) {
      if (current()) this.setRegistry({ reviewFile: { id, path, status: "error", error: message(error) } });
    }
  }

  /**
   * Approve or Reject. A reject needs a reason of 8 to 500 characters, checked here and again by
   * the Cloud. An approve shows the host's native sheet first; a declined sheet is a no-op.
   */
  async decide(id: string, decision: ReviewDecision, reason: string): Promise<boolean> {
    if (!this.client || this.snapshot.registry.busy) return false;
    const text = reason.trim();
    if (decision === "reject" && !validRejectReason(text)) {
      this.setRegistry({ reviewFormError: "store.registry.reasonLength" });
      return false;
    }
    this.setRegistry({ busy: id, reviewFormError: undefined });
    try {
      // The app and version name the host's sheet; the Cloud decides by id.
      const row = this.snapshot.registry.queue.find((q) => q.id === id);
      const named = row ? { app: row.app, version: row.version } : {};
      await this.client.call(RegistryOps.reviewDecide, { id, decision, reason: text, ...named });
    } catch (error) {
      this.setRegistry({ busy: undefined });
      if (!isCode(error, CANCELLED)) this.set(failure(error));
      return false;
    }
    this.setRegistry({ busy: undefined, reviewSelection: undefined, reviewFile: undefined });
    if (this.snapshot.error) this.set({ error: undefined });
    await this.loadQueue();
    return true;
  }

  private setRegistry(patch: Partial<RegistrySnapshot>): void {
    this.set({ registry: { ...this.snapshot.registry, ...patch } });
  }

  private set(patch: Partial<AppsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

/** A random key; `getRandomValues` works outside secure contexts, unlike `randomUUID`. */
function newKey(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return `pg_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function updateFromInstalled(app: InstalledApp): AppUpdate[] {
  return app.update
    ? [
        {
          app: app.id,
          name: app.name,
          current_version: app.version,
          version: app.update.version,
          failure: app.failure,
        },
      ]
    : [];
}

/** A reject reason the Cloud accepts: 8 to 500 characters after trimming. */
export function validRejectReason(reason: string): boolean {
  // The Cloud's own count (UTF-16 length of the trimmed reason), so the page and server agree.
  const length = reason.trim().length;
  return length >= REJECT_REASON.min && length <= REJECT_REASON.max;
}

function isCode(error: unknown, code: string): boolean {
  return isPageError(error) && error.code === code;
}

/** An older host without the registry ops shows no registry at all, not an error. */
function registryStatus(error: unknown): RegistryStatus {
  if (isCode(error, SIGNED_OUT)) return "signed-out";
  if (isCode(error, "cmux.protocol.unknown_op")) return "unavailable";
  return "error";
}

function failure(error: unknown): Partial<AppsSnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected", error: error.message };
  return { error: message(error) };
}
