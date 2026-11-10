import { isPageError, type PageClient } from "../../pages/shared/pageClient";
import type { SceneAssetResolver } from "./SceneRenderer";
import { SceneStore, type SceneLimits, type SceneOp, type SceneViolation } from "./store";

/** A page panel: a Session Info section, or a New Tab widget (`size` is a widget's cell). */
export type AppPanel = { app: string; section: string; title: string; symbol?: string; size?: "small" | "wide" };
export type MountContext = { session_id: string; cwd?: string; branch?: string; harness?: string };
/** A New Tab widget's mount context (`cmux.newtab.widget/1`): the page, not a chat. */
export type NewTabMountContext = { surface: "newTab" };
/** Where a mount shows (`cmux.apps.panels.mount {surface}`); the host resolves the app's implementation for it. */
export type MountSurface = "pane" | "sidebarSection" | "hoverCard" | "sessionInfoSection" | "newTab";
/** The scene stream's two events: an ops batch, or the mount's status (`loading`, `ready`,
 * `failed {reason}`, `disconnected {reason}`). */
export type SceneEvent =
  | { mount_id: string; ops: SceneOp[]; reset?: boolean }
  | { mount_id: string; status: "loading" | "ready" | "failed" | "disconnected"; reason?: string };
export const panelId = (panel: AppPanel): `app:${string}#${string}` => `app:${panel.app}#${panel.section}`;
/** Why a mounted panel draws nothing: its mount failed, or its scene broke its interface's limits
 * (it is unmounted then). Absent while it draws. */
export type PanelProblem = { kind: "failed" } | { kind: "over"; violation: SceneViolation };
export type MountedPanel = {
  panel: AppPanel;
  store: SceneStore;
  dispatch: (node: string, event: string, payload?: unknown) => void;
  /** The failure row's Reload: runs the app's saved script again. Call it synchronously from the click. */
  reload: () => void;
  /** Reports the drawn height, so the host can size a native frame around the page (sent once per change). */
  layout: (height: number) => void;
  /** The mount's bundle images, once the host serves them (`asset_base` in the mount reply). */
  resolveAsset: SceneAssetResolver;
  problem?: PanelProblem;
};
/** What a page shows: every listed panel (the New Tab page's Add Widgets lists them), the person's
 * layout (New Tab only: placed widget ids and built-in names, in order), and the mounted ones. */
export type PanelsView = {
  readonly panels: readonly AppPanel[];
  readonly layout: readonly string[];
  readonly mounted: readonly MountedPanel[];
  /** The host lists this interface with a layout and saves `layout.set`. A host that does not (an
   * older Mac bridge drops `interface` and `layout`, and refuses `layout.set`) gets no edits. */
  readonly editable: boolean;
};
export type PanelsOptions = {
  /** The interface listed (`cmux.apps.panels.list {interface}`); Session Info's sections when unset. */
  interface?: string;
  /** The interface's scene limits (`nodes`, `maxNodes`), applied to each mount's store. */
  limits?: SceneLimits;
  /** Which listed panels mount (New Tab: the placed ones); all when unset. */
  mounts?: (panel: AppPanel, layout: readonly string[]) => boolean;
};
type Entry = MountedPanel & {
  cancelled: boolean;
  failed: boolean;
  mountId?: string;
  assetBase?: string;
  /** The drawn height the page measured last, and the one the host last heard. */
  height?: number;
  sentHeight?: number;
  unsubscribe?: () => void;
};

/** A bundle-relative path (already checked by the renderer) under the host's asset base, each
 * component encoded once, so a decoded `%2F` can never become a separator. */
export function bundleAssetURL(base: string, path: string): string | undefined {
  try {
    const parts = path.split("/").map((part) => decodeURIComponent(part));
    if (parts.some((part) => !part || part === "." || part === ".." || part.includes("/") || part.includes("\\")))
      return undefined;
    return base + parts.map(encodeURIComponent).join("/");
  } catch {
    return undefined;
  }
}
const EMPTY: readonly MountedPanel[] = [];
const EMPTY_VIEW: PanelsView = { panels: [], layout: [], mounted: EMPTY, editable: false };

function readPanels(value: unknown): AppPanel[] {
  const panels = (value as { panels?: unknown } | null)?.panels;
  if (!Array.isArray(panels)) return [];
  const seen = new Set<string>();
  return panels
    .filter((panel): panel is AppPanel => {
      if (
        !panel ||
        typeof panel !== "object" ||
        typeof panel.app !== "string" ||
        !panel.app ||
        typeof panel.section !== "string" ||
        !panel.section ||
        typeof panel.title !== "string"
      )
        return false;
      const id = panelId(panel);
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    })
    .map(({ app, section, title, symbol, size }) => ({
      app,
      section,
      title,
      ...(typeof symbol === "string" && { symbol }),
      ...((size === "small" || size === "wide") && { size }),
    }));
}

/** The listing's layout; `undefined` when the host sent none (it does not keep one). */
function readLayout(value: unknown): string[] | undefined {
  const layout = (value as { layout?: unknown } | null)?.layout;
  if (!Array.isArray(layout)) return undefined;
  return [...new Set(layout.filter((id): id is string => typeof id === "string" && id.length > 0))];
}

function sameIds(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((id, index) => id === b[index]);
}

/** One pane/context's mount lifetime. Scene events notify the touched scene nodes only, never the
 * panel list. Entries exist before mount starts so concurrent list updates cannot mount twice. */
export class AppPanelsClient {
  private snapshot: readonly MountedPanel[] = EMPTY;
  private view: PanelsView = EMPTY_VIEW;
  private listed: readonly AppPanel[] = [];
  private layout: readonly string[] = [];
  /** The layout the host last listed: what a refused save falls back to. */
  private saved: readonly string[] = [];
  private editable = false;
  /** The host answered `layout.set` with unknown-op: it keeps no layout, for this client's life. */
  private refused = false;
  private readonly listeners = new Set<() => void>();
  private readonly entries = new Map<ReturnType<typeof panelId>, Entry>();
  private active = false;
  private lifetime = 0;
  private listing = 0;
  private edits = 0;
  private unwatch?: () => void;

  constructor(
    private readonly client: PageClient | null,
    private readonly context: MountContext | NewTabMountContext | undefined,
    private readonly options: PanelsOptions = {},
  ) {}
  getSnapshot = (): readonly MountedPanel[] => this.snapshot;
  getView = (): PanelsView => this.view;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  /** Session Info mounts per chat; another interface mounts per page. */
  private get ready(): boolean {
    if (!this.client || !this.context) return false;
    return this.options.interface !== undefined || ("session_id" in this.context && !!this.context.session_id);
  }

  start(): void {
    if (this.active || !this.ready) return;
    this.active = true;
    const lifetime = ++this.lifetime;
    void this.client!.subscribe("cmux.apps.panels.changed", () => {
      if (this.active && lifetime === this.lifetime) void this.refresh();
    })
      .then((stop) => {
        if (!this.active || lifetime !== this.lifetime) stop();
        else {
          this.unwatch = stop;
          // The eager list may have answered before the host installed this subscription.
          // Read once with the watch active so a change in that gap cannot be missed.
          void this.refresh();
        }
      })
      .catch(() => undefined);
    void this.refresh();
  }

  stop(): void {
    this.active = false;
    ++this.lifetime;
    ++this.listing;
    this.unwatch?.();
    this.unwatch = undefined;
    for (const entry of this.entries.values()) this.release(entry);
    this.entries.clear();
    this.snapshot = EMPTY;
    this.view = EMPTY_VIEW;
  }

  async refresh(): Promise<void> {
    if (!this.active || !this.client) return;
    const listing = ++this.listing;
    const edits = this.edits;
    let reply: unknown;
    try {
      reply = await this.client.call(
        "cmux.apps.panels.list",
        this.options.interface ? { interface: this.options.interface } : {},
      );
    } catch {
      reply = undefined;
    } // An older host offers no sections and no user-facing error.
    if (!this.active || listing !== this.listing) return;
    // Only this interface's panels: a host that ignores the filter (it lists Session Info's
    // sections) yields none, so nothing else is offered or mounted here.
    const wanted = this.options.interface;
    this.listed = readPanels(reply).filter((panel) => !wanted || panel.section === wanted);
    const listedLayout = wanted && !this.refused ? readLayout(reply) : undefined;
    this.editable = listedLayout !== undefined;
    const layout = listedLayout ?? [];
    this.saved = layout;
    // A layout edited while this list was in flight is newer than the one it read.
    if (edits === this.edits && !sameIds(layout, this.layout)) this.layout = layout;
    this.reconcile(true);
  }

  /** The New Tab page's edit mode: the person's new layout, drawn at once and saved by the daemon
   * (`apps.panels.layout.set`). Called from the click, drop or key handler itself: the page host checks
   * the gesture. */
  setLayout(layout: readonly string[]): void {
    if (!this.active || !this.client || !this.options.interface || !this.editable) return;
    const next = [...new Set(layout)];
    if (sameIds(next, this.layout)) return;
    this.layout = next;
    const edit = ++this.edits;
    const lifetime = this.lifetime;
    void this.client
      .call("cmux.apps.panels.layout.set", {
        interface: this.options.interface,
        layout: next,
        idempotency_key: `newtab-layout-${Date.now()}-${edit}`,
      })
      .then(
        () => {
          if (edit === this.edits) this.saved = next;
        },
        (error: unknown) => {
          if (!this.active || lifetime !== this.lifetime) return;
          // An unsaved edit is not shown as saved: the row goes back to the host's layout. A host
          // without the op keeps no layout at all, so edits end here.
          if (isPageError(error) && error.code === "cmux.protocol.unknown_op") {
            this.refused = true;
            this.editable = false;
            this.saved = [];
          }
          if (edit !== this.edits && !this.refused) return;
          this.layout = this.saved;
          this.reconcile(false);
        },
      );
    this.reconcile(false);
  }

  /** `retry`: a list read again retries the mounts that failed (a fixed app gets another chance);
   * a layout edit or a failure never does, so a failing widget cannot loop. */
  private reconcile(retry: boolean): void {
    const panels = this.listed;
    const layout = this.layout;
    const mounts = this.options.mounts;
    const shown = mounts ? panels.filter((panel) => mounts(panel, layout)) : panels;
    const wanted = new Set(shown.map(panelId));
    for (const [id, entry] of this.entries) {
      if (wanted.has(id)) continue;
      this.release(entry);
      this.entries.delete(id);
    }
    const next = shown.map((panel) => {
      const id = panelId(panel);
      let entry = this.entries.get(id);
      if (entry?.failed && retry) {
        this.release(entry);
        this.entries.delete(id);
        entry = undefined;
      }
      if (!entry) {
        const created: Entry = {
          panel,
          store: new SceneStore(this.options.limits),
          cancelled: false,
          failed: false,
          dispatch: (node, event, payload) => {
            if (!this.active || created.cancelled || !created.mountId) return;
            void this.client
              ?.call("cmux.apps.panels.dispatch", {
                mount_id: created.mountId,
                node,
                event,
                ...(payload !== undefined && { payload }),
              })
              .catch(() => undefined);
          },
          reload: () => {
            if (!this.active || created.cancelled || !created.mountId) return;
            void this.client?.call("cmux.apps.panels.reload", { mount_id: created.mountId }).catch(() => undefined);
          },
          layout: (height) => {
            const rounded = Math.max(0, Math.ceil(height));
            if (!this.active || created.cancelled || !Number.isFinite(rounded)) return;
            created.height = rounded;
            // Before the mount answers, the height waits for it (`mount` sends it then).
            this.sendLayout(created);
          },
          resolveAsset: (path) => (created.assetBase ? bundleAssetURL(created.assetBase, path) : undefined),
        };
        entry = created;
        this.entries.set(id, entry);
        void this.mount(entry);
      } else if (
        entry.panel.title !== panel.title ||
        entry.panel.symbol !== panel.symbol ||
        entry.panel.size !== panel.size
      ) {
        entry.panel = panel;
      }
      // A separate snapshot prevents later metadata updates mutating a prior render's value.
      return {
        panel: entry.panel,
        store: entry.store,
        dispatch: entry.dispatch,
        reload: entry.reload,
        layout: entry.layout,
        resolveAsset: entry.resolveAsset,
        ...(entry.problem && { problem: entry.problem }),
      };
    });
    const sameMounted =
      next.length === this.snapshot.length &&
      next.every((entry, index) => {
        const old = this.snapshot[index];
        return old?.panel === entry.panel && old.store === entry.store && old.problem === entry.problem;
      });
    const sameView =
      sameMounted &&
      this.view.layout === layout &&
      this.view.editable === this.editable &&
      this.view.panels.length === panels.length &&
      panels.every((panel, index) => {
        const old = this.view.panels[index];
        return (
          old !== undefined &&
          panelId(old) === panelId(panel) &&
          old.title === panel.title &&
          old.symbol === panel.symbol &&
          old.size === panel.size
        );
      });
    if (sameView) return;
    if (!sameMounted) this.snapshot = next;
    this.view = { panels, layout, mounted: this.snapshot, editable: this.editable };
    this.notify();
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }

  /** A mount that failed or broke its limits: the page shows why in its place. */
  private fail(entry: Entry, problem: PanelProblem): void {
    entry.failed = true;
    if (entry.cancelled) return;
    entry.problem = problem;
    this.reconcile(false);
  }

  private async mount(entry: Entry): Promise<void> {
    const client = this.client!;
    try {
      const result = await client.call<{ mount_id?: unknown; asset_base?: unknown }>("cmux.apps.panels.mount", {
        surface: (this.context && "surface" in this.context
          ? this.context.surface
          : "sessionInfoSection") satisfies MountSurface,
        app: entry.panel.app,
        section: entry.panel.section,
        context: this.context,
      });
      if (typeof result?.mount_id !== "string" || !result.mount_id) {
        this.failMount(entry);
        return;
      }
      entry.mountId = result.mount_id;
      if (typeof result.asset_base === "string" && result.asset_base.endsWith("/")) entry.assetBase = result.asset_base;
      if (entry.cancelled) {
        this.unmount(entry);
        return;
      }
      const mountId = result.mount_id;
      const stop = await client.subscribe<SceneEvent>(
        "cmux.apps.panels.scene",
        (event) => {
          if (entry.cancelled || event?.mount_id !== mountId) return;
          if ("status" in event) {
            entry.store.setStatus(event.status, event.reason);
            return;
          }
          if (!Array.isArray(event.ops)) return;
          entry.store.apply(event.ops, event.reset === true);
          const violation = entry.store.violation;
          if (violation && this.options.limits) {
            // Over its interface's limits: it stops (no more work in its VM for this page) and says why.
            entry.unsubscribe?.();
            entry.unsubscribe = undefined;
            this.unmount(entry);
            this.fail(entry, { kind: "over", violation });
          }
        },
        { mount_id: mountId },
      );
      if (entry.cancelled || entry.failed) stop();
      else {
        entry.unsubscribe = stop;
        this.sendLayout(entry);
      }
    } catch (error) {
      // The row says why, as the host's model does when its mount call fails; the next list mounts again.
      if (!entry.cancelled) entry.store.setStatus("failed", error instanceof Error ? error.message : String(error));
      this.unmount(entry); // A failed scene subscription must not leave a daemon mount alive.
      this.failMount(entry);
    }
  }

  /** Session Info keeps a failed section empty (it retries on the next list); another interface
   * shows the failure in the panel's place. */
  private failMount(entry: Entry): void {
    if (this.options.interface) this.fail(entry, { kind: "failed" });
    else entry.failed = true;
  }

  private sendLayout(entry: Entry): void {
    const { mountId, height } = entry;
    if (!this.active || entry.cancelled || !mountId || height === undefined || height === entry.sentHeight) return;
    entry.sentHeight = height;
    void this.client?.call("cmux.apps.panels.layout", { mount_id: mountId, height }).catch(() => undefined);
  }

  private unmount(entry: Entry): void {
    if (!entry.mountId) return;
    const mountId = entry.mountId;
    entry.mountId = undefined;
    void this.client?.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined);
  }

  private release(entry: Entry): void {
    entry.cancelled = true;
    entry.unsubscribe?.();
    entry.unsubscribe = undefined;
    this.unmount(entry);
  }
}

let devClient: PageClient | null = null;
/** The browser dev entry installs its mock before React mounts. Production never selects a mock
 * from a URL, and tests/gallery can inject their own PageClient directly. */
export function installAppPanelsDevClient(client: PageClient): void {
  devClient = client;
}
export function appPanelsDevClient(): PageClient | null {
  return devClient;
}
