// The App Store page's state on the page side: a projection of the app supervisor
// (`cmux.apps.catalog.list`, `installed.list`, `grants.get`, the `watch` stream) plus view state
// (tab, query, category, selection). No optimistic copy: every mutation re-reads after the owner
// answers, and install, uninstall, update and grant changes go through the host's native
// confirmation (coordinator Q4), so the page shows the owner's result, never its own guess.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import { fromDetail, listCatalog, listInstalled, type WireDetail } from "./wire";
import { categories, filterApps, listedInStore, parseRoute, type StoreLayout, type StoreTab } from "./model";
import {
  AppsOps,
  type AppDetail,
  type AppsChanged,
  type CatalogApp,
  type Grants,
  type InstalledApp,
  type LogLine,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export interface AppsSnapshot {
  tab: StoreTab;
  layout: StoreLayout;
  query: string;
  category?: string;
  catalog: CatalogApp[];
  /** The catalog filtered by query and category. */
  visible: CatalogApp[];
  categories: string[];
  installed: InstalledApp[];
  selection?: string;
  detail?: AppDetail;
  grants: Record<string, Grants>;
  /** Installed row panels. */
  grantsShown?: string;
  logsShown?: string;
  logs: Record<string, LogLine[]>;
  loading: boolean;
  connection: Connection;
  error?: string;
}

const LOG_LINES = 200;

/** The host's code for a declined native sheet: the person said no, which is not an error. */
const CANCELLED = "cmux.page.cancelled";

export class AppsStore {
  private snapshot: AppsSnapshot;
  private readonly listeners = new Set<() => void>();
  private unwatch?: () => void;
  private unlog?: () => void;
  private unpage?: () => void;
  private starting = false;
  private generation = 0;
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
      query: "",
      catalog: [],
      visible: [],
      categories: [],
      installed: [],
      selection: route.app && listedInStore({ id: route.app }) ? route.app : undefined,
      grants: {},
      logs: {},
      loading: client !== null,
      connection: client ? "connecting" : "disconnected",
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
    await this.reload();
  }

  /** The host reports the owner link: down shows the disconnected state; back up re-reads. */
  private onConnection(connected: boolean): void {
    if (!connected) {
      this.set({ connection: "disconnected", loading: false });
    } else if (this.snapshot.connection === "disconnected") {
      this.set({ connection: "connecting" });
      void this.reload();
    }
  }

  stop(): void {
    this.unpage?.();
    this.unpage = undefined;
    this.starting = false;
    this.unwatch?.();
    this.unwatch = undefined;
    this.unlog?.();
    this.unlog = undefined;
  }

  /** Re-reads the catalog, the installed list, and the selected app's detail. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const [catalog, installed] = await Promise.all([listCatalog(this.client), listInstalled(this.client)]);
      if (generation !== this.generation) return;
      const listed = catalog.apps.filter(listedInStore);
      this.set({
        catalog: listed,
        visible: filterApps(listed, this.snapshot.query, this.snapshot.category),
        categories: categories(listed),
        installed: installed.apps.filter(listedInStore),
        loading: false,
        connection: "connected",
        error: undefined,
      });
      if (this.snapshot.selection) await this.loadDetail(this.snapshot.selection);
      if (this.snapshot.grantsShown) await this.loadGrants(this.snapshot.grantsShown);
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
    }
  }

  /** The host set a new fragment (`appStore.show {app}`, `showInstalled`): its tab and listing. */
  applyRoute(hash: string): void {
    const route = parseRoute(hash);
    this.setTab(route.tab);
    if (route.layout !== this.snapshot.layout) this.set({ layout: route.layout });
    if (route.app !== this.snapshot.selection) void this.select(route.app);
  }

  setTab(tab: StoreTab): void {
    if (tab !== this.snapshot.tab)
      this.set({ tab, selection: this.snapshot.layout === "split" ? this.snapshot.selection : undefined });
  }

  setQuery(query: string): void {
    this.set({ query, visible: filterApps(this.snapshot.catalog, query, this.snapshot.category) });
  }

  setCategory(category: string | undefined): void {
    const next = this.snapshot.category === category ? undefined : category;
    this.set({ category: next, visible: filterApps(this.snapshot.catalog, this.snapshot.query, next) });
  }

  async select(app: string | undefined): Promise<void> {
    if (app && !listedInStore({ id: app })) app = undefined;
    this.set({ selection: app, detail: app === this.snapshot.detail?.id ? this.snapshot.detail : undefined });
    if (app) await this.loadDetail(app);
  }

  private async loadDetail(app: string): Promise<void> {
    if (!this.client) return;
    const generation = ++this.detailGeneration;
    try {
      const detail = fromDetail(await this.client.call<WireDetail>(AppsOps.catalogGet, { app }));
      if (generation === this.detailGeneration && this.snapshot.selection === app) this.set({ detail });
      if (detail.installed) await this.loadGrants(app);
    } catch (error) {
      if (generation === this.detailGeneration) this.set(failure(error));
    }
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

  /** Shows or hides an installed app's logs; shown logs follow the owner's stream. */
  async toggleLogs(app: string): Promise<void> {
    this.unlog?.();
    this.unlog = undefined;
    const shown = this.snapshot.logsShown === app ? undefined : app;
    this.set({ logsShown: shown, logs: shown ? { ...this.snapshot.logs, [app]: [] } : this.snapshot.logs });
    if (!shown || !this.client) return;
    try {
      this.unlog = await this.client.subscribe<{ line: LogLine }>(
        AppsOps.logs,
        (event) => {
          const lines = [...(this.snapshot.logs[app] ?? []), event.line].slice(-LOG_LINES);
          this.set({ logs: { ...this.snapshot.logs, [app]: lines } });
        },
        { app, follow: true },
      );
    } catch (error) {
      this.set(failure(error));
    }
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

  /** Hides or shows an app in the app areas; the only way to put a first-party app away. */
  setHidden(app: string, hidden: boolean): Promise<void> {
    return this.intent(AppsOps.set, { app, hidden });
  }

  setSandboxed(app: string, sandboxed: boolean): Promise<void> {
    return this.intent(AppsOps.set, { app, sandboxed });
  }

  setGranted(app: string, scope: string, granted: boolean): Promise<void> {
    return this.intent(AppsOps.grantSet, { app, scope, granted });
  }

  open(app: string): Promise<void> {
    return this.intent(AppsOps.open, { app, focus: true }, { reread: false, mutation: false });
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

function failure(error: unknown): Partial<AppsSnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected", error: error.message };
  return { error: message(error) };
}
